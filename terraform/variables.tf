variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "domain" {
  description = "Route53 hosted zone domain you already own (e.g. example.com) — the server and API get FQDNs under this"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for `domain` (already exists — this stack only adds records to it, doesn't create the zone)"
  type        = string
}

variable "vpc_id" {
  description = "VPC to launch the instance into (must have an internet-routable subnet — see subnet_id)"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet (in vpc_id) for the Valheim EC2 instance — needs a route to an internet gateway"
  type        = string
}

variable "instance_type" {
  description = "4 vCPU / 16GB (t3.xlarge) — comfortable for ~6 concurrent players. t3.medium (2vCPU/4GB) is Valheim's documented bare minimum for 1-2 players; c5.xlarge/m5.xlarge cost slightly more but have no CPU-credit throttling risk if sustained sessions ever show lag"
  type        = string
  default     = "t3.xlarge"
}

variable "data_volume_size_gb" {
  description = "Size of the EBS volume holding the Valheim world saves + install dir"
  type        = number
  default     = 15
}

variable "server_name" {
  description = "Name shown in Valheim's in-game server browser"
  type        = string
  default     = "My Valheim Server"
}

variable "world_name" {
  description = "Changing this alone does nothing to the live instance — user_data only runs on true first boot. Switching worlds means SSM'ing in and re-running the container by hand; see README.md."
  type        = string
  default     = "MyWorld"
}

variable "server_args" {
  description = "Extra Valheim dedicated-server CLI flags (world modifiers etc., e.g. \"-modifier combat hard -modifier resources more\") — only take effect when a world is first generated. Same live-instance caveat as world_name."
  type        = string
  default     = ""
}

variable "admin_steamids" {
  description = "SteamID64s granted admin (kick/ban/console). Populate with your friend group's IDs."
  type        = list(string)
  default     = []
}

variable "discord_webhook_url" {
  description = "Optional Discord webhook for server start/stop/backup notifications"
  type        = string
  default     = ""
  sensitive   = true
}

variable "idle_window_minutes" {
  description = "Trailing window over which average network activity is measured for idle detection"
  type        = number
  default     = 30
}

variable "idle_grace_period_minutes" {
  description = "Minutes after instance start during which auto-stop is skipped, so a fresh boot isn't stopped before anyone connects"
  type        = number
  default     = 20
}

variable "idle_threshold_bytes" {
  description = "Average NetworkIn (bytes) below which the server is considered idle. Heuristic — tune after watching real CloudWatch metrics for your own server/players."
  type        = number
  default     = 100000
}

variable "discord_application_id" {
  description = "Optional: Discord application (client) ID for the bot — from the Developer Portal's General Information page. Not secret. Leave blank to skip the Discord slash-command integration."
  type        = string
  default     = ""
}

variable "discord_public_key" {
  description = "Optional: Discord application public key (hex, from the same Developer Portal page) — verifies Ed25519-signed interaction requests. Not secret; Discord expects this to be public. Leave blank to skip the Discord slash-command integration (the /discord route will just reject every request with 401)."
  type        = string
  default     = ""
}

variable "manage_api_gateway_account" {
  description = "Whether this stack creates the account-level API Gateway CloudWatch logging role (aws_api_gateway_account). That setting is a singleton per AWS account/region — leave this true unless another Terraform stack in the same account already manages it, in which case set it false here to avoid two stacks fighting over the same resource."
  type        = bool
  default     = true
}

variable "repo_tag" {
  description = "Value for the Repo default tag applied to every resource this stack creates — override if you forked/renamed this repo."
  type        = string
  default     = "samdammers/valheim-aws-template"
}
