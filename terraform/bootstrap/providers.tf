terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # No backend block on purpose. This directory runs with local state so it can
  # create the bucket that every other directory uses. See backend.tf.example
  # and step 2 of docs/02-backend.md for migrating this state into the bucket
  # once it exists.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Component = "terraform-backend"
    }
  }
}
