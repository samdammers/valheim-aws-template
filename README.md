# Valheim on AWS

Valheim dedicated server on a single EC2 instance, managed by Terraform, with an
API-driven start/stop + idle-auto-stop layer so the server (and its bill) isn't
running 24/7 — plus an optional Discord slash-command integration
(`/valheim-start`, `/valheim-stop`, `/valheim-status`).

This is a template: every account-specific value (domain, AWS account, VPC, …) is
a variable you supply, not a default baked into the repo. See [Prerequisites](#prerequisites)
and [Configure](#configure) below.

## Architecture

```
valheim.<your-domain> (Route53 A, static)
  → Elastic IP
    → EC2 instance (t3.xlarge, Amazon Linux 2023, on-demand)
        ├── Docker: ghcr.io/lloesche/valheim-server (community-valheim-tools/valheim-server-docker)
        │     UDP 2456-2458
        └── EBS data volume → /config (world saves) + /opt/valheim (game install)
              — persists automatically across stop/start
              — snapshotted weekly by AWS Backup (safety net)

api.valheim.<your-domain>
  → API Gateway REST (Prod)
    → Lambda valheim-manager
        ├── GET  /start    — start the EC2 instance
        ├── GET  /stop     — stop the EC2 instance
        ├── GET  /status   — instance state + public IP
        └── POST /discord  — Discord Interactions webhook (slash commands below)

Discord slash commands (/valheim-start, /valheim-stop, /valheim-status)
  → same Lambda, via the /discord route — Ed25519-signature-authenticated,
    no persistent bot/gateway connection needed. /valheim-start and
    /valheim-status also reply (ephemerally) with the connect address + password.

EventBridge (every 10 min) → Lambda { scheduled_action: "check_idle" }
  → stops the instance automatically if average network activity has been
    low for the last idle_window_minutes (and it's not still within its
    post-start grace period)
```

EC2 (not ECS/Fargate) is deliberate: plain stop/start already preserves the attached
EBS volume, which is exactly what "start on demand, stop when idle" needs, without
extra backup/restore machinery. A static Elastic IP means DNS never needs to change
across stop/start, unlike an ECS/Fargate task, which gets a new IP on every start.

## Prerequisites

You need, already existing in your own AWS account before running `terraform apply`:

- A Route53 **public hosted zone** for a domain you own (this stack only adds
  records to it — it doesn't register a domain or create the zone).
- A **VPC with a public subnet** (has a route to an internet gateway) — the default
  VPC in any AWS region works fine if you don't have a custom one.
- Terraform >= 1.16, and the AWS CLI authenticated (this stack uses the CLI's default
  credential chain — no hardcoded profile).
- An S3 bucket you own, for Terraform remote state (or skip remote state for a quick
  trial — see [Configure](#configure)).

## Configure

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars   # fill in domain, hosted_zone_id, vpc_id, subnet_id, etc.
cp backend.hcl.example backend.hcl             # fill in your state bucket (or delete backend.tf for local state)

terraform init -backend-config=backend.hcl
terraform apply
```

`terraform.tfvars` and `backend.hcl` are both gitignored — see `terraform.tfvars.example`
and `backend.hcl.example` for the full list of variables and their descriptions
(`terraform/variables.tf` is the source of truth).

Then populate the server password (never stored in Terraform state):

```bash
aws secretsmanager put-secret-value \
  --secret-id valheim/credentials \
  --secret-string '{"SERVER_PASS":"your-password-here"}' \
  --region <your-aws-region>
```

The password only takes effect on the container's *next first boot* — either
`terraform apply -replace=aws_instance.valheim` for a clean fresh boot (old world
data is untouched, since it lives on the separate EBS data volume, not the instance),
or SSM into the box and re-run the `docker run` command by hand for a one-off change
without a full replace.

## Day-to-day operations

### Start / stop

```bash
curl https://api.valheim.<your-domain>/start
curl https://api.valheim.<your-domain>/stop
curl https://api.valheim.<your-domain>/status

# Or directly via CLI
aws ec2 start-instances --instance-ids <instance-id> --region <your-aws-region>
aws ec2 stop-instances --instance-ids <instance-id> --region <your-aws-region>
```

The server auto-stops itself after `idle_window_minutes` of low network activity
(checked every 10 minutes, with `idle_grace_period_minutes` after each start so a
fresh boot isn't stopped before anyone connects). Tune these three variables in
`terraform/variables.tf` (or your `terraform.tfvars`) once you've watched real
CloudWatch `NetworkIn` numbers for a few sessions — the defaults are a starting
heuristic, not a measured value.

### Connecting

Add server: `valheim.<your-domain>` (or the Elastic IP from `terraform output elastic_ip`),
port 2456. Give it ~1-2 minutes after `/start` for Docker to boot and the game server
to come up.

### Logs / admin shell

No SSH — connect via SSM Session Manager:

```bash
aws ssm start-session --target <instance-id> --region <your-aws-region>
sudo docker logs -f valheim
```

### Admins / whitelist

Add SteamID64s to `admin_steamids` in your `terraform.tfvars` and `terraform apply`
— this rewrites user-data, which only takes effect on a fresh instance (see caveats
below). For a same-session change without a full replace, SSM in and re-run the
container with updated `ADMINLIST_IDS`.

### Discord bot (optional)

Slash commands `/valheim-start`, `/valheim-stop`, `/valheim-status` — same Lambda,
via the `/discord` webhook route, no separate hosting. Skip this whole section if you
don't want it (leave `discord_application_id`/`discord_public_key` blank in your
tfvars — the `/discord` route just rejects every request with 401 in that case).

1. Create a Discord application in the [Developer Portal](https://discord.com/developers/applications).
2. Set `discord_application_id` / `discord_public_key` in your `terraform.tfvars`
   (from the app's General Information page — not secret) and `terraform apply`.
3. Set the app's **Interactions Endpoint URL** to `terraform output discord_interactions_url`.
4. Push the bot token: `aws secretsmanager put-secret-value --secret-id valheim/discord-bot-token --secret-string "..." --region <your-aws-region>` (never via Terraform/git).
5. `DISCORD_APPLICATION_ID=<id> AWS_REGION=<your-aws-region> ./scripts/register-discord-commands.sh` — re-run only if the command list itself changes (this is a bulk-overwrite of Discord's global command list, not a merge).
6. Invite/re-invite the app to your server with **both** `bot` and `applications.commands`
   OAuth2 scopes (Developer Portal → OAuth2 → URL Generator) — without
   `applications.commands`, the commands won't appear in that server even though
   they're registered globally.

### Creating a new world (world modifiers, difficulty, seed)

World modifiers only take effect when a world is **first generated** — changing
`world_name` or `server_args` in Terraform does nothing to a world that already
exists on disk. Two ways to actually create a new one:

- **Clean (recommended)**: `terraform apply -replace=aws_instance.valheim` — destroys
  and recreates just the EC2 instance. The EBS data volume is a separate resource and
  isn't touched; the Elastic IP re-associates automatically (no DNS change). The
  fresh instance's first-boot `user_data` runs for real this time, generating a new
  world under whatever `world_name` is currently set.
- **Manual**: SSM in, `docker rm -f valheim`, then re-run the `docker run` command
  from `templates/user_data.sh.tftpl` by hand with the new `WORLD_NAME`/`SERVER_ARGS`
  env vars.

The old world's files aren't touched by either path above — they just sit alongside
the new one on the data volume unless explicitly removed. If you don't want to keep
the old world, delete it first (SSM in, before or after the switch-over):
```bash
sudo rm -f /mnt/valheim-data/config/worlds_local/<OldWorldName>.db /mnt/valheim-data/config/worlds_local/<OldWorldName>.fwl
```
(Any hourly local backups of it under `/mnt/valheim-data/config/backups/` are separate
— remove those too if you want a clean slate; they're not touched by AWS Backup's
weekly EBS *volume* snapshots either way.)

World seed has no CLI flag at all — the only way to pin one is generating it locally
in a normal Valheim client first, then uploading the resulting `.db`/`.fwl` files to
the volume before first boot. World size has no exposed setting at all — it's a fixed
radius in vanilla Valheim; changing it needs the third-party "Expand World Size" mod
(BepInEx), which this template doesn't run.

## Terraform

All infrastructure is in `terraform/`. Uses the AWS CLI default credential chain (no
hardcoded profile) — make sure your CLI is authenticated before running.

| File | Purpose |
|---|---|
| `variables.tf` | Every input this stack takes — see `terraform.tfvars.example` |
| `ec2.tf` | EC2 instance, EBS data volume + attachment, Elastic IP |
| `security_groups.tf` | UDP 2456-2458 ingress only — no SSH |
| `templates/user_data.sh.tftpl` | First-boot script: installs Docker, mounts the data volume, runs the container |
| `lambda.tf` | Lambda function + EventBridge idle-check rule + PyNaCl vendoring (`null_resource`) |
| `lambda/manager.py` | Lambda handler — start/stop/status, idle auto-stop, Discord interactions |
| `lambda/requirements.txt` | PyNaCl — vendored into the zip for Discord's Ed25519 signature verification |
| `apigateway.tf` | REST API — `/start` `/stop` `/status` `/discord`, custom domain |
| `acm.tf` | Regional ACM cert for the API custom domain (DNS-validated) |
| `dns.tf` | Route53 — static A record to the EIP + API custom domain alias |
| `iam.tf` | EC2 instance role (SSM + Secrets Manager), Lambda role, API Gateway account-level CloudWatch role |
| `secrets.tf` | Secrets Manager secret (password set out-of-band) |
| `backup.tf` | AWS Backup — weekly EBS snapshot, 8-week retention |
| `backend.tf` | S3 state backend (partial config — see `backend.hcl.example`), native `use_lockfile` locking (no DynamoDB) |

### Important caveats

- **`user_data` only runs on first boot** (standard cloud-init behavior) — it is *not*
  re-run on every `/start`. This is fine for our stop/start pattern: the data volume
  auto-mounts via `/etc/fstab` on every boot, and Docker restarts the container
  (`--restart unless-stopped`) whenever the daemon starts. But it means changing
  `server_name`, `world_name`, `server_args`, `admin_steamids`, etc. won't take effect
  until the instance is replaced (`terraform apply -replace=aws_instance.valheim` —
  safe, the EBS data volume isn't touched) or you make the change by hand over SSM.
- **The API Gateway account-level CloudWatch logging role** (`aws_api_gateway_account`)
  is a singleton per AWS account/region. This stack manages it by default
  (`manage_api_gateway_account = true`) so `terraform apply` works standalone in a
  fresh account — if you're layering this alongside another Terraform stack that
  already manages that same setting in the same account, set
  `manage_api_gateway_account = false` here instead, or the two stacks will fight
  over it (and risk clobbering it on `destroy`).
- **Idle-stop is heuristic** — it uses average `NetworkIn` over a trailing window,
  not actual player count. Watch real metrics for a session or two and tune
  `idle_window_minutes`, `idle_grace_period_minutes`, `idle_threshold_bytes` in your
  `terraform.tfvars`.
- **Elastic IP costs a small hourly fee** even while the instance is stopped (AWS
  bills all EIPs regardless of attachment state) — a few cents a month, not worth
  optimizing away for the DNS stability it buys.

## Backups

The data EBS volume is snapshotted weekly (Tuesday 3am AEST — adjust the cron in
`backup.tf` for your own timezone/schedule preference) via AWS Backup
(`valheim-backup` vault, 8-week retention), on top of the Docker image's own hourly
local backups inside `/config` (`BACKUPS_MAX_AGE=3` days).

To trigger a one-off snapshot before a risky change:

```bash
ROLE=$(aws iam get-role --role-name valheim-backup-role --query Role.Arn --output text --region <your-aws-region>)
aws backup start-backup-job \
  --backup-vault-name valheim-backup \
  --resource-arn "$(terraform output -raw data_volume_arn)" \
  --iam-role-arn "$ROLE" \
  --region <your-aws-region>
```
