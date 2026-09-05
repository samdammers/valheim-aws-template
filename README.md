# Valheim on AWS

Valheim dedicated server on a single EC2 instance, managed by Terraform, with an
API-driven start/stop + idle-auto-stop layer so the server (and its bill) isn't
running 24/7 — plus an optional Discord slash-command integration
(`/valheim-start`, `/valheim-stop`, `/valheim-status`).

This is a template: every account-specific value (domain, AWS account, VPC, …) is
a variable you supply, not a default baked into the repo. See [Prerequisites](#prerequisites)
and [Configure](#configure) below.

> **Setting up a brand-new personal AWS account?** [samdammers/aws](https://github.com/samdammers/aws)
> bootstraps secure sign-in (Google login via Auth0 + IAM Identity Center, no IAM
> user password) plus baseline guardrails (CloudTrail, an org-wide SCP, cost
> anomaly alerts) — a good first step before deploying stacks like this one. It's
> optional and independent: it doesn't create the VPC, hosted zone, or state
> bucket this template needs (see [Prerequisites](#prerequisites)).

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

### 1. An AWS account, with an authenticated CLI

If you don't have one: [sign up here](https://portal.aws.amazon.com/billing/signup)
(needs a credit card, but this stack's monthly cost is small — see
[Cost](#cost) below). Then, rather than using the root login day-to-day, create an
IAM user or role for yourself and install/configure the AWS CLI:

- [Creating an IAM user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html)
- [Installing the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Configuring the CLI with your credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html)
  (`aws configure`) — this stack uses the CLI's default credential chain, no
  hardcoded profile, so whatever `aws sts get-caller-identity` resolves to is what
  Terraform will use.

**Permissions:** this stack creates IAM roles/policies for itself (EC2 instance
role, Lambda role, backup role, API Gateway logging role), on top of EC2, Lambda,
API Gateway, Route53, ACM, Secrets Manager, CloudWatch, and S3 (state) resources.
For a personal project like this, the simplest path is an IAM user/role with the
AWS-managed `AdministratorAccess` policy — a scoped-down policy is possible but
isn't provided here, since Terraform creating IAM roles on your behalf inherently
needs broad IAM permissions itself.

### 2. A domain, delegated to a Route53 hosted zone

This stack only **adds records to** an existing Route53 public hosted zone — it
doesn't register a domain or create the zone for you. Two ways to get one:

- **Register a new domain directly through Route53** (simplest — the hosted zone
  is created for you automatically):
  [Registering a new domain](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/domain-register.html)
- **Already own a domain elsewhere** (Namecheap, GoDaddy, etc.): create a hosted
  zone for it in Route53, then update your registrar's nameserver (NS) records to
  point at the four nameservers Route53 gives you:
  [Working with hosted zones](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/AboutHZWorkingWith.html)

Either way, once it's set up you'll have a `hosted_zone_id` (looks like
`Z0123456789ABCDEFGHIJ`) — find it any time with:
```bash
aws route53 list-hosted-zones-by-name --dns-name <your-domain>
```

### 3. A VPC with a public subnet

The **default VPC** that every AWS region already has works fine — you don't need
to create a custom one. ([What's a default VPC?](https://docs.aws.amazon.com/vpc/latest/userguide/default-vpc.html))
Find your default VPC and one of its subnets with:
```bash
aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text --region <your-aws-region>
aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id-from-above> --query 'Subnets[0].SubnetId' --output text --region <your-aws-region>
```
Any subnet in the default VPC is public (has a route to an internet gateway), so
the first one returned is fine.

### 4. Terraform, and an S3 bucket for its state

Install Terraform >= 1.16: [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install)

Then create an S3 bucket you don't already use for anything else
([Creating a bucket](https://docs.aws.amazon.com/AmazonS3/latest/userguide/creating-bucket.html)),
e.g.:
```bash
aws s3api create-bucket --bucket <your-unique-bucket-name> --region <your-aws-region>
```
(Or skip this and use local state for a quick trial — see [Configure](#configure).)

## Cost

The EC2 instance only bills while it's actually running (that's the point of
idle auto-stop), at whatever the current on-demand rate is for your chosen
`instance_type` and region — check
[EC2 on-demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/) for a
figure, since it varies by region and changes over time. On top of that, small
fixed costs run whether or not the server is up: the 15GB `gp3` EBS volume, the
Elastic IP's hourly fee (billed even while stopped), the Route53 hosted zone
(~$0.50/month if you created it just for this), weekly EBS backup storage, and
S3 for Terraform state — all together typically a few dollars a month. Lambda
and API Gateway are effectively free at this call volume (well under the
AWS free tier).

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
via the `/discord` webhook route, no separate hosting (no always-on bot process to
run anywhere). Skip this whole section if you don't want it: leave
`discord_application_id`/`discord_public_key` blank in your tfvars and the
`/discord` route just rejects every request with 401.

There are two separate Discord credentials involved and it's easy to mix them up:
a **public key** (goes in Terraform, verifies that requests really came from
Discord — not secret) and a **bot token** (goes in Secrets Manager, used once to
register the commands — a real secret, never commit it or put it in `.tfvars`).

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
   → **New Application**, give it a name. This is the one-time app setup Discord's
   own docs walk through in more detail if you want it:
   [Discord: Overview of Apps](https://discord.com/developers/docs/quick-start/overview-of-apps).
2. On the app's **General Information** page, copy the **Application ID** and
   **Public Key** into `discord_application_id` / `discord_public_key` in your
   `terraform.tfvars`, then `terraform apply`.
3. Still on **General Information**, set **Interactions Endpoint URL** to the value
   of `terraform output discord_interactions_url`. Discord immediately sends a test
   request here and will refuse to save the URL unless the Lambda is already
   deployed with the matching public key — so this step has to come *after* step 2's
   `apply`, not before.
4. On the **Bot** tab, click **Reset Token** to reveal the bot token, then push it
   straight to Secrets Manager (never through Terraform or git):
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id valheim/discord-bot-token \
     --secret-string "<paste-the-bot-token>" \
     --region <your-aws-region>
   ```
5. Register the slash commands with Discord (one-off; re-run only if the command
   list itself changes — this bulk-overwrites Discord's global command list for
   your app, it doesn't merge):
   ```bash
   DISCORD_APPLICATION_ID=<id> AWS_REGION=<your-aws-region> ./scripts/register-discord-commands.sh
   ```
6. On the **OAuth2 → URL Generator** tab, check **both** the `bot` and
   `applications.commands` scopes, open the generated URL, and invite the app to
   your server. Without `applications.commands` checked, the commands won't show up
   in that server even though they're registered globally in step 5.

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
