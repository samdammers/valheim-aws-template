# Populated out-of-band, not via Terraform, so the password never lands in state:
#   aws secretsmanager put-secret-value \
#     --secret-id valheim/credentials \
#     --secret-string '{"SERVER_PASS":"..."}' \
#     --region <your-aws-region>
resource "aws_secretsmanager_secret" "valheim" {
  name        = "valheim/credentials"
  description = "Valheim server password (SERVER_PASS), populated manually after first apply"
  tags        = local.tags
}

# The Lambda itself never needs this — it only verifies request signatures with the
# (non-secret) public key. This is used solely by scripts/register-discord-commands.sh
# to register slash commands via Discord's REST API, run manually/out-of-band:
#   aws secretsmanager put-secret-value \
#     --secret-id valheim/discord-bot-token \
#     --secret-string "your-bot-token-here" \
#     --region <your-aws-region>
resource "aws_secretsmanager_secret" "discord_bot_token" {
  name        = "valheim/discord-bot-token"
  description = "Discord bot token, populated manually — only used for one-off slash command registration, never by the Lambda"
  tags        = local.tags
}
