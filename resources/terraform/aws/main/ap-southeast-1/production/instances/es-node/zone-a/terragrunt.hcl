include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${dirname(find_in_parent_folders())}/../../../provisioners/terraform-aws-modules//instance"
}

inputs = {
  instance_name_prefix                    = "es-node"
  instance_amount                         = 3
  instance_ami                            = "ami-03cc493b9a33586c1"
  instance_type                           = "t3.small"
  instance_key_name                       = "personal-aws-prod"
  instance_subnet_id                      = "subnet-0212d0e3e7cfae325"
  instance_root_block_device_volume_size  = "20"
  vpc_id                                  = "vpc-0ccf257265147c0e0"
  instance_port                           = [9200, 9300]
  ssh_allowed_cidr                        = "0.0.0.0/0"
  
  userdata_vars = {
    hostgroup   = "es-node"
    port        = 9200
    environment = "production"
  }
}