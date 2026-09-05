# Partial backend config - bucket/key/region are consumer-specific, so they're not
# hardcoded here. Copy backend.hcl.example to backend.hcl (gitignored), fill in your
# own values (an S3 bucket you already own), then:
#   terraform init -backend-config=backend.hcl
# (If you run `terraform init` without -backend-config, Terraform will prompt
# interactively for bucket/key/region instead of failing outright.)
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
