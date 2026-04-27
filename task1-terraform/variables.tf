# =====================================================================
# Credentials — never hardcode. Set via:
#   export HW_ACCESS_KEY=...   export HW_SECRET_KEY=...
# =====================================================================
variable "hw_access_key" {
  description = "Huawei Cloud Access Key (AK). Prefer setting via HW_ACCESS_KEY env var."
  type        = string
  sensitive   = true
}

variable "hw_secret_key" {
  description = "Huawei Cloud Secret Key (SK). Prefer setting via HW_SECRET_KEY env var."
  type        = string
  sensitive   = true
}

# =====================================================================
# Region / tagging
# =====================================================================
variable "region" {
  description = "Huawei Cloud region"
  type        = string
  default     = "ap-southeast-3"
}

variable "availability_zones" {
  description = "List of AZs for ELB; first AZ is used for ECS + EVS."
  type        = list(string)
  default     = ["ap-southeast-3a"]
}

variable "project_name" {
  description = "Prefix used in all resource names / tags."
  type        = string
  default     = "metabase"
}

variable "environment" {
  description = "Environment tag (dev / staging / prod)."
  type        = string
  default     = "dev"
}

# =====================================================================
# Network
# =====================================================================
variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR (ECS + ELB)."
  type        = string
  default     = "10.20.1.0/24"
}

variable "allowed_http_cidr" {
  description = "CIDRs allowed to reach the public ELB on port 80 (tighten in prod)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_allowed_cidr" {
  description = "Single CIDR allowed to SSH the ECS (for debugging). Empty = SSH disabled."
  type        = string
  default     = ""
}

variable "ssh_keypair_name" {
  description = "Existing Huawei Cloud key pair name to attach to ECS. Empty = no key."
  type        = string
  default     = ""
}

# =====================================================================
# ECS
# =====================================================================
variable "metabase_image_id" {
  description = "Ubuntu 22.04 IMS image ID in the chosen region (Console → IMS → Public Images)."
  type        = string
}

variable "metabase_flavor" {
  description = "ECS flavor — must have ≥ 4 GB RAM for Metabase + Postgres."
  type        = string
  default     = "s6.large.2"
}

variable "metabase_docker_tag" {
  description = "Metabase Docker image tag."
  type        = string
  default     = "v0.50.20"
}

# =====================================================================
# Storage — separate EVS for /var/lib/docker (persistent app + DB data)
# =====================================================================
variable "data_volume_size_gb" {
  description = "EVS volume size attached as /dev/vdb and mounted to /var/lib/docker."
  type        = number
  default     = 50
}
