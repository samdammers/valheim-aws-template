#!/bin/bash
# One-off (and idempotent) registration of the Valheim slash commands with Discord.
# Re-run this whenever the command list below changes. The bot token never touches
# this script's arguments/history - it's read straight from Secrets Manager.
set -euo pipefail

: "${DISCORD_APPLICATION_ID:?Set DISCORD_APPLICATION_ID (from the Developer Portal)}"
: "${AWS_REGION:?Set AWS_REGION to the region you deployed this stack into}"

BOT_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id valheim/discord-bot-token \
  --region "$AWS_REGION" \
  --query SecretString --output text)

curl -sS -X PUT "https://discord.com/api/v10/applications/${DISCORD_APPLICATION_ID}/commands" \
  -H "Authorization: Bot ${BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '[
    {"name": "valheim-start", "description": "Start the Valheim server"},
    {"name": "valheim-stop", "description": "Stop the Valheim server"},
    {"name": "valheim-status", "description": "Check whether the Valheim server is running"}
  ]'
echo
echo "Slash commands registered."
