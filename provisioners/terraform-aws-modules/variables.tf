variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-1"
}

variable "aws_allowed_account_ids" {
  description = "List of allowed AWS account IDs for safety checks"
  type        = list(string)
}

variable "aws_account_name" {
  description = "A friendly name for the AWS account"
  type        = string
}

variable "managed_via" {
  description = "ManagedVia default tag value"
  type        = string
}