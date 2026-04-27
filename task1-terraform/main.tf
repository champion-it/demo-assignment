locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# =====================================================================
# Networking — single public subnet for ECS. Postgres lives INSIDE the
# ECS as a Docker container in an `internal: true` network — never
# exposed to the host or the VPC.
# =====================================================================
resource "huaweicloud_vpc" "this" {
  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr
  tags = local.common_tags
}

resource "huaweicloud_vpc_subnet" "public" {
  name       = "${local.name_prefix}-subnet-public"
  vpc_id     = huaweicloud_vpc.this.id
  cidr       = var.public_subnet_cidr
  gateway_ip = cidrhost(var.public_subnet_cidr, 1)
  dns_list   = ["100.125.1.250", "100.125.21.250"]
  tags       = local.common_tags
}

# =====================================================================
# Security Groups — only 80/HTTP from allowed CIDRs lands on the ELB,
# only 3000 from the ELB SG lands on ECS. 5432 is never opened anywhere.
# =====================================================================
resource "huaweicloud_networking_secgroup" "elb" {
  name                 = "${local.name_prefix}-sg-elb"
  description          = "Public ELB fronting Metabase"
  delete_default_rules = true
}

resource "huaweicloud_networking_secgroup_rule" "elb_http_in" {
  for_each          = toset(var.allowed_http_cidr)
  security_group_id = huaweicloud_networking_secgroup.elb.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  ports             = "80"
  remote_ip_prefix  = each.value
}

resource "huaweicloud_networking_secgroup_rule" "elb_egress" {
  security_group_id = huaweicloud_networking_secgroup.elb.id
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "0.0.0.0/0"
}

resource "huaweicloud_networking_secgroup" "metabase" {
  name                 = "${local.name_prefix}-sg-metabase"
  description          = "Metabase ECS — accepts 3000/tcp from ELB SG only"
  delete_default_rules = true
}

resource "huaweicloud_networking_secgroup_rule" "metabase_from_elb" {
  security_group_id = huaweicloud_networking_secgroup.metabase.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  ports             = "3000"
  remote_group_id   = huaweicloud_networking_secgroup.elb.id
}

resource "huaweicloud_networking_secgroup_rule" "metabase_egress" {
  security_group_id = huaweicloud_networking_secgroup.metabase.id
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "0.0.0.0/0"
}

# Optional SSH from a single CIDR — disabled by default; enable for debugging.
resource "huaweicloud_networking_secgroup_rule" "metabase_ssh" {
  count             = var.ssh_allowed_cidr == "" ? 0 : 1
  security_group_id = huaweicloud_networking_secgroup.metabase.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  ports             = "22"
  remote_ip_prefix  = var.ssh_allowed_cidr
}

# =====================================================================
# Secret — random DB password stored in CSMS. The password is also
# rendered into ECS user_data via cloud-init `write_files` so the stack
# comes up without needing an IAM Agency on first boot. Both copies stay
# in sync because Terraform owns the source of truth (`random_password`).
# =====================================================================
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!@#%^*_-+="
}

resource "huaweicloud_csms_secret" "db" {
  name        = "${local.name_prefix}-db-credentials"
  description = "Metabase Postgres credentials (managed by docker-compose on ECS)"
  secret_text = jsonencode({
    username = "metabase"
    password = random_password.db.result
    dbname   = "metabase"
  })
}

# =====================================================================
# EVS data volume — persistent storage for Postgres + Metabase volumes
# (mounted at /var/lib/docker by install.sh).
# =====================================================================
resource "huaweicloud_evs_volume" "data" {
  name              = "${local.name_prefix}-data"
  volume_type       = "SSD"
  size              = var.data_volume_size_gb
  availability_zone = var.availability_zones[0]
  tags              = local.common_tags
}

# =====================================================================
# ECS — Ubuntu 22.04 with cloud-init bootstrap.
# =====================================================================
locals {
  compose_yaml = templatefile("${path.module}/templates/docker-compose.yml.tpl", {
    metabase_tag = var.metabase_docker_tag
  })
  install_script = file("${path.module}/templates/install.sh")
}

data "cloudinit_config" "metabase" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content = yamlencode({
      package_update  = false
      package_upgrade = false
      write_files = [
        {
          path        = "/opt/metabase/docker-compose.yml"
          permissions = "0644"
          owner       = "root:root"
          content     = local.compose_yaml
        },
        {
          path        = "/opt/metabase/.secrets/db_password"
          permissions = "0600"
          owner       = "root:root"
          content     = random_password.db.result
        },
        {
          path        = "/opt/metabase/install.sh"
          permissions = "0755"
          owner       = "root:root"
          content     = local.install_script
        },
      ]
      runcmd = ["/opt/metabase/install.sh"]
    })
  }
}

resource "huaweicloud_compute_instance" "metabase" {
  name               = "${local.name_prefix}-ecs"
  image_id           = var.metabase_image_id
  flavor_id          = var.metabase_flavor
  security_group_ids = [huaweicloud_networking_secgroup.metabase.id]
  availability_zone  = var.availability_zones[0]
  key_pair           = var.ssh_keypair_name == "" ? null : var.ssh_keypair_name

  network {
    uuid = huaweicloud_vpc_subnet.public.id
  }

  user_data = data.cloudinit_config.metabase.rendered
  tags      = local.common_tags
}

# Attach the EVS volume — install.sh formats + mounts it.
resource "huaweicloud_compute_volume_attach" "data" {
  instance_id = huaweicloud_compute_instance.metabase.id
  volume_id   = huaweicloud_evs_volume.data.id
}

# =====================================================================
# ELB — public Layer-7 load balancer; HTTP 80 → ECS:3000.
# Add an HTTPS listener + SCM cert for production.
# =====================================================================
resource "huaweicloud_vpc_eip" "elb" {
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name        = "${local.name_prefix}-elb-bw"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }
  tags = local.common_tags
}

resource "huaweicloud_elb_loadbalancer" "this" {
  name              = "${local.name_prefix}-elb"
  vpc_id            = huaweicloud_vpc.this.id
  ipv4_subnet_id    = huaweicloud_vpc_subnet.public.ipv4_subnet_id
  availability_zone = var.availability_zones
  ipv4_eip_id       = huaweicloud_vpc_eip.elb.id
  tags              = local.common_tags
}

resource "huaweicloud_elb_pool" "metabase" {
  name            = "${local.name_prefix}-pool"
  protocol        = "HTTP"
  lb_method       = "ROUND_ROBIN"
  loadbalancer_id = huaweicloud_elb_loadbalancer.this.id
}

resource "huaweicloud_elb_member" "metabase" {
  pool_id       = huaweicloud_elb_pool.metabase.id
  address       = huaweicloud_compute_instance.metabase.access_ip_v4
  protocol_port = 3000
  subnet_id     = huaweicloud_vpc_subnet.public.ipv4_subnet_id
}

resource "huaweicloud_elb_listener" "http" {
  name            = "${local.name_prefix}-http"
  loadbalancer_id = huaweicloud_elb_loadbalancer.this.id
  protocol        = "HTTP"
  protocol_port   = 80
  default_pool_id = huaweicloud_elb_pool.metabase.id
}

resource "huaweicloud_elb_monitor" "metabase" {
  pool_id     = huaweicloud_elb_pool.metabase.id
  protocol    = "HTTP"
  interval    = 10
  timeout     = 5
  max_retries = 3
  url_path    = "/api/health"
}
