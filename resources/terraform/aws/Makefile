ifndef dir
$(error dir variable is undefined. Usage: make plan dir=path/to/dir)
endif

.PHONY: init plan apply destroy

init:
	terragrunt init --terragrunt-working-dir $(dir)

plan:
	terragrunt plan --target=$(dir)

apply:
	terragrunt apply --terragrunt-working-dir $(dir)

destroy:
	terragrunt destroy --terragrunt-working-dir $(dir)