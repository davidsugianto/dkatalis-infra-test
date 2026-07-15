remote_state {
  backend = "local"
  config  = {
    path = "${get_terragrunt_dir()}/states/${path_relative_to_include()}/terraform.tfstate"
  }
}

locals {
  modules_dir = "${dirname(find_in_parent_folders())}/../../../provisioners/terraform-aws-modules"
}

generate "providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = file("${local.modules_dir}/providers.tf")
}

generate "global_variables" {
  path      = "global_variables.tf"
  if_exists = "overwrite_terragrunt"
  contents  = file("${local.modules_dir}/variables.tf")
}

terraform {
  extra_arguments "extra" {
    commands = "${get_terraform_commands_that_need_vars()}"
    required_var_files = [
        find_in_parent_folders("global.tfvars"),
        find_in_parent_folders("account.tfvars"),
    ]
    optional_var_files = [
        find_in_parent_folders("region.tfvars", "ignore"),
        find_in_parent_folders("network.tfvars", "ignore"),
    ]
  }
}
