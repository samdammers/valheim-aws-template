# Static - the Elastic IP doesn't change across stop/start, so (unlike an ECS/Fargate
# setup, where every task start gets a new ENI/IP) there's no dynamic-DNS-on-boot
# Lambda needed here.
resource "aws_route53_record" "valheim" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.server_fqdn
  type    = "A"
  ttl     = 300
  records = [aws_eip.valheim.public_ip]
}

resource "aws_route53_record" "api_valheim" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.api_fqdn
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.valheim.regional_domain_name
    zone_id                = aws_api_gateway_domain_name.valheim.regional_zone_id
    evaluate_target_health = false
  }
}
