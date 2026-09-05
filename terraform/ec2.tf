# --- World data volume ---
# Survives instance stop/start automatically (EBS volumes stay attached — this is
# not the ephemeral-storage problem Fargate has). Sized to hold both the /config
# saves and the /opt/valheim install dir, so a restart doesn't need to redownload
# the game via SteamCMD.
resource "aws_ebs_volume" "valheim_data" {
  availability_zone = data.aws_subnet.valheim.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.tags, { Name = "valheim-data" })
}

resource "aws_instance" "valheim" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.valheim.id]
  iam_instance_profile   = aws_iam_instance_profile.valheim.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 10
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    server_name         = var.server_name
    world_name          = var.world_name
    admin_steamids      = join(" ", var.admin_steamids)
    discord_webhook_url = var.discord_webhook_url
    server_args         = var.server_args
    secret_arn          = aws_secretsmanager_secret.valheim.arn
    region              = local.region
  })

  tags = merge(local.tags, { Name = "valheim-server" })

  lifecycle {
    # The SSM AMI parameter rolls to a new patch version regularly — don't force a
    # replace (and thus a re-run of first-boot user_data) on every apply.
    ignore_changes = [ami]
  }
}

resource "aws_volume_attachment" "valheim_data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.valheim_data.id
  instance_id = aws_instance.valheim.id
}

resource "aws_eip" "valheim" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "valheim-eip" })
}

resource "aws_eip_association" "valheim" {
  instance_id   = aws_instance.valheim.id
  allocation_id = aws_eip.valheim.id
}
