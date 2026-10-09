#
# Partial backend configuration
# -----------------------------
# The bucket name contains your AWS account ID, so it cannot be committed as a
# literal if this repo is public. Everything that is NOT account specific lives
# here; bucket and region come from backend.hcl, which is gitignored.
#
#   cp backend.hcl.example backend.hcl     # fill in the bucket from the bootstrap output
#   terraform init -backend-config=backend.hcl
#
# use_lockfile = true is the state locking mechanism. Terraform writes
# envs/dev/terraform.tfstate.tflock into the same bucket with a conditional
# write, so two applies cannot both hold it. There is no DynamoDB table: the
# dynamodb_table argument was deprecated in Terraform 1.11 and the lock file
# approach has been the supported one since 1.10.
#
terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
