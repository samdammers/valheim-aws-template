output "server_address" {
  description = "Connect to this address in Valheim's server browser (or direct connect)"
  value       = local.server_fqdn
}

output "elastic_ip" {
  value = aws_eip.valheim.public_ip
}

output "instance_id" {
  value = aws_instance.valheim.id
}

output "data_volume_id" {
  value = aws_ebs_volume.valheim_data.id
}

output "data_volume_arn" {
  description = "For one-off `aws backup start-backup-job --resource-arn ...` snapshots — see README"
  value       = "arn:aws:ec2:${local.region}:${data.aws_caller_identity.current.account_id}:volume/${aws_ebs_volume.valheim_data.id}"
}

output "api_invoke_url" {
  description = "Direct API Gateway invoke URL — works even before the custom domain propagates"
  value       = aws_api_gateway_stage.valheim.invoke_url
}

output "api_url" {
  value = "https://${local.api_fqdn}"
}

output "secrets_manager_arn" {
  description = "Populate with: aws secretsmanager put-secret-value --secret-id valheim/credentials --secret-string '{\"SERVER_PASS\":\"...\"}'"
  value       = aws_secretsmanager_secret.valheim.arn
}

output "discord_interactions_url" {
  description = "Paste into the Discord app's General Information > Interactions Endpoint URL"
  value       = "https://${local.api_fqdn}/discord"
}
