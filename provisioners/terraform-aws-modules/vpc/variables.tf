variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks, one per public subnet"
  type        = list(string)
}

variable "availability_zones" {
  description = "AZs matching public_subnet_cidrs by index"
  type        = list(string)
}

variable "environment" {
  description = "Environment tag"
  type        = string
}
