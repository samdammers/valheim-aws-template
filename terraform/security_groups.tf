# --- Valheim EC2 Security Group ---
resource "aws_security_group" "valheim" {
  name        = "valheim-sg"
  description = "Valheim dedicated server: game ports from anywhere, all outbound"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "valheim-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "valheim_game_ports" {
  security_group_id = aws_security_group.valheim.id
  description       = "Valheim game/query/crossplay ports"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 2456
  to_port           = 2458
}

# No SSH ingress — admin shell access is via SSM Session Manager only.
resource "aws_vpc_security_group_egress_rule" "valheim_out" {
  security_group_id = aws_security_group.valheim.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
