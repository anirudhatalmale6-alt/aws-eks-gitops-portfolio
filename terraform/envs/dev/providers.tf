terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # default_tags applies these to every resource the provider creates, including
  # resources inside modules that never thought about tagging. Cost allocation in
  # Cost Explorer is only useful if the tags are actually there, and this is the
  # one place that guarantees it.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "${var.github_owner}/${var.github_repo}"
    }
  }
}
