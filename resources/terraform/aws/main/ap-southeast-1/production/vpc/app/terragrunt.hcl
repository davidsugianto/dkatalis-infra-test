include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${dirname(find_in_parent_folders())}/../../../provisioners/terraform-aws-modules//vpc"
}

inputs = {
  environment         = "production"
  vpc_cidr            = "10.0.0.0/16"
}