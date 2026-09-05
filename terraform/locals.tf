locals {
  name_prefix = "valheim"
  region      = var.aws_region

  server_fqdn = "valheim.${var.domain}"
  api_fqdn    = "api.valheim.${var.domain}"

  tags = {
    Service = "valheim"
  }
}
