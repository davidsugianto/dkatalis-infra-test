variable "instance_name_prefix" {
  description = "Short name prefix, e.g. testapp, kibana, es-master or es-data"
  type        = string
}

variable "instance_amount" {
  description = "Number of EC2 instances to create"
  type        = number
  default     = 1
}

variable "instance_ami" {
  description = "Instance AMI ID to use for the EC2 instance"
  type        = string
}

variable "vpc_id" {
  description = "VPC to launch the instance into"
  type        = string
}

variable "instance_subnet_id" {
  description = "Subnet to launch the instance into"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t2.micro"
  type        = string
}

variable "instance_root_block_device_volume_size" {
  description = "Size (in GiB) of the root EBS volume"
  type        = number
  default     = 8
}

variable "instance_key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH into the instance"
  type        = string
}

variable "environment" {
  description = "Environment tag"
  type        = string
}

variable "instance_port" {
  description = "Instance port to open in the security group"
  type        = number
}

variable "userdata_vars" {
  description = "Variables passed into the userdata.sh.tpl template"
  type        = map(any)
}
