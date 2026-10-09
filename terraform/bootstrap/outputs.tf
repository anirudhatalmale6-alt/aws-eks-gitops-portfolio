output "state_bucket_name" {
  description = "Name of the state bucket. This is the value for the backend's bucket argument."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket, for scoping the CI roles' S3 permissions."
  value       = aws_s3_bucket.state.arn
}

output "state_bucket_region" {
  description = "Region of the state bucket. The backend needs this explicitly; it is not inferred from your shell."
  value       = data.aws_region.current.region
}

output "backend_block" {
  description = "The exact backend block to paste into terraform/envs/<env>/backend.tf. Note use_lockfile and the absence of any DynamoDB table."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.state.id}"
        key          = "envs/dev/terraform.tfstate"
        region       = "${data.aws_region.current.region}"
        encrypt      = true
        use_lockfile = true
      }
    }
  EOT
}
