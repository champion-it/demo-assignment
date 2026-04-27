output "metabase_url" {
  description = "Public URL of Metabase. Allow ~3-5 min after apply for ECS boot + Docker install + first-run DB migration."
  value       = "http://${huaweicloud_vpc_eip.elb.address}"
}

output "elb_public_ip" {
  value = huaweicloud_vpc_eip.elb.address
}

output "ecs_private_ip" {
  description = "Internal IP of the ECS — for SSH debug only (SSH must be enabled via ssh_allowed_cidr)."
  value       = huaweicloud_compute_instance.metabase.access_ip_v4
}

output "db_secret_name" {
  description = "CSMS secret holding DB credentials. Read with: hcloud csms secret show --name <name>"
  value       = huaweicloud_csms_secret.db.name
}

output "db_password" {
  description = "Generated DB password (sensitive)."
  value       = random_password.db.result
  sensitive   = true
}
