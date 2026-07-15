terraform {
  required_version = ">= 1.5.0"

  backend "local" {} # Terragrunt fills this in via remote_state

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = var.aws_allowed_account_ids

  default_tags {
    tags = {
      account_name = var.aws_account_name
      managed_via  = var.managed_via
    }
  }
}
