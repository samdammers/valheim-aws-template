# CLAUDE.md — valheim-aws-template

Context for future work in this repo. See `README.md` for day-to-day operator commands.

## What this is

A single EC2 instance running the Valheim dedicated server (via the community
`ghcr.io/lloesche/valheim-server` Docker image), managed by Terraform, with an
API-driven start/stop + idle-auto-stop layer (REST API → Lambda → AWS SDK action,
EventBridge-triggered scheduled Lambda invocations, per-stage CloudWatch access
logging, tightly-scoped IAM), meant to be forked/cloned and configured with your
own AWS account, domain, and VPC — not run as-is.

Key design choices, and why:
- **EC2, not ECS/Fargate.** No need for EFS/CloudFront/containers here — plain EC2
  stop/start already preserves attached EBS volumes, which is exactly what a "start
  on demand, stop when idle" pattern needs without extra S3 backup/restore machinery.
- **Idle-detection auto-stop, not a fixed cron.** Play sessions are irregular, so the
  EventBridge rule invokes the Lambda every 10 minutes with `{"scheduled_action":
  "check_idle"}`, and the Lambda decides based on trailing average `NetworkIn` —
  see `terraform/lambda/manager.py`.
- **Static Elastic IP, not dynamic DNS.** An ECS/Fargate task gets a new ENI/IP every
  start, which would need a start-triggered Route53 update. EC2 keeps the same EIP
  across stop/start, so `dns.tf` just points a static A record at it — no
  dynamic-update Lambda trigger needed.

Also has an optional Discord slash-command integration (`/valheim-start` etc.)
bolted onto the same Lambda via a `POST /discord` route — deliberately a plain
HTTPS Interactions webhook (Ed25519-signature-authenticated), not a persistent
gateway-connected bot, since running a 24/7 bot process would undercut the whole
point of EC2 idle auto-stop. `PyNaCl` is vendored into the Lambda zip (see
`lambda.tf`'s `null_resource`) rather than depending on a third-party Lambda Layer
of uncertain regional availability.

## This is a template, not a deployed stack

Every account-specific value (domain, hosted zone ID, VPC/subnet, AWS region,
Discord app credentials) is a `variable` with **no default** in `variables.tf` (or a
generic placeholder default) — consumers supply their own via `terraform.tfvars`
(see `terraform.tfvars.example`). Similarly, `backend.tf` is a *partial* S3 backend
config — bucket/key/region come from `-backend-config=backend.hcl`
(`backend.hcl.example`), since a hardcoded state bucket would point every consumer's
Terraform at the same bucket. If you're adding a new account-specific value, follow
that pattern: variable with no default (or a generic placeholder) + an entry in
`terraform.tfvars.example`, never a real value baked into a `.tf` file's default.

## Important caveats (see README for the full list)

- `user_data` (`terraform/templates/user_data.sh.tftpl`) only runs on the instance's
  *first* boot — changing server config variables in Terraform does nothing to a
  running instance until it's replaced (`terraform apply -replace=aws_instance.valheim`
  is safe — the EBS data volume is a separate resource, untouched by instance
  replacement, and the EIP/DNS re-associate automatically). Docker's
  `--restart unless-stopped` plus the EBS volume's `/etc/fstab` entry are what make
  subsequent stop/start cycles work without re-running user_data.
- **Lambda's `architectures` attribute must be set explicitly, never omitted.** The AWS
  provider treats a removed `architectures` line as "leave whatever's already
  deployed," not "reset to the true default" — this caused a real bug where vendored
  x86_64 PyNaCl wheels got deployed onto a function still configured for arm64.
- Constructing `boto3.client("ec2")` costs real, CPU-bound seconds (EC2's service model
  is huge) — this is why the Lambda's memory is 512MB (Lambda CPU scales with memory)
  and why the Discord `PING` handshake path is written to never touch boto3 at all. A
  3+ second PING response was the actual root cause of a "endpoint could not be
  verified" Discord error — not a signature-verification bug, despite how it first
  looked from the 401/200 pattern in the logs.
- **`aws_api_gateway_account` (the account-level CloudWatch logging role for API
  Gateway) is created by default** (`manage_api_gateway_account = true`) so this
  stack applies cleanly standalone in a fresh account. That setting is a singleton
  per AWS account/region, though — if a consumer is running this alongside another
  Terraform stack that already owns it, they need `manage_api_gateway_account = false`
  here, or the two stacks fight over (and risk clobbering on `destroy`) the same
  resource. Don't quietly flip the default to `false` — that would break the common
  single-stack case to accommodate the uncommon multi-stack one.
- The idle-stop thresholds in `variables.tf` (`idle_window_minutes`,
  `idle_grace_period_minutes`, `idle_threshold_bytes`) are an unvalidated starting
  heuristic — every consumer's play patterns differ, so don't treat them as tuned.
- The server password lives in Secrets Manager (`valheim/credentials`), populated
  out-of-band via `aws secretsmanager put-secret-value` — never put it in a `.tfvars`
  file or Terraform state.
