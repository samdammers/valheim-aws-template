# Safety net on top of the EBS volume already surviving stop/start - protects against
# accidental deletion/corruption of the world data volume itself.
resource "aws_iam_role" "backup" {
  name = "valheim-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_vault" "valheim" {
  name = "valheim-backup"
  tags = local.tags
}

resource "aws_backup_plan" "valheim" {
  name = "valheim-weekly"

  rule {
    rule_name         = "weekly-3am-aest-wednesday"
    target_vault_name = aws_backup_vault.valheim.name
    schedule          = "cron(0 17 ? * TUE *)" # 3am AEST Wednesday = 17:00 UTC Tuesday

    lifecycle {
      delete_after = 56 # 8 weekly backups
    }
  }

  tags = local.tags
}

resource "aws_backup_selection" "valheim" {
  name         = "valheim-ebs"
  plan_id      = aws_backup_plan.valheim.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [
    "arn:aws:ec2:${local.region}:${data.aws_caller_identity.current.account_id}:volume/${aws_ebs_volume.valheim_data.id}"
  ]
}
