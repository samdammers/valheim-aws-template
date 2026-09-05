data "aws_caller_identity" "current" {}

data "aws_route53_zone" "main" {
  zone_id = var.hosted_zone_id
}

data "aws_subnet" "valheim" {
  id = var.subnet_id
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
