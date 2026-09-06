# Update bucket, key, and region to match your own S3 state bucket (or delete
# this file entirely for local state). The bucket must exist before running
# terraform init. Never commit your real bucket name here - keep this edit
# uncommitted, or fork this file privately.
terraform {
  backend "s3" {
    bucket       = "your-terraform-state-bucket"
    key          = "valheim/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
