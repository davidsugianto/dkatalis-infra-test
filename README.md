# dkatalis-infra-test

A Technical Home Test for the DKatalis Cloud Infrastructure Engineer position.

This repository provisions an AWS EC2 instance with **Terraform + Terragrunt** and bootstraps a secured **Elasticsearch 8.x** node (authentication + TLS on both HTTP and transport layers) with **Ansible**. A smoke-test script verifies the node works end to end over HTTPS with credentials.

> Full solution write-up, design decisions, and answers to the exercise questions: see [INSTRUCTIONS.md](./INSTRUCTIONS.md).

## Architecture Overview

```
Terraform/Terragrunt                     Ansible
┌─────────────────────────┐   tags      ┌──────────────────────────────┐
│ vpc module              │  hostgroup  │ aws_ec2 dynamic inventory    │
│  VPC, IGW, subnets, RT  │ ──────────► │  targets tag_Hostgroup_*     │
│ instance module         │             │ roles:                       │
│  SG + EC2 (+ userdata)  │             │  common (base OS)            │
└─────────────────────────┘             │  elasticsearch (install,     │
                                        │   TLS, vaulted credentials)  │
                                        └──────────────────────────────┘
```

The repo is a **monorepo** split into two layers:

- `provisioners/` — reusable building blocks (Terraform modules, Ansible roles/playbooks)
- `resources/` — live environment configuration (Terragrunt hierarchy: account → region → environment → stack)

Adding new infrastructure later is plug-and-play: create a new `terragrunt.hcl`, plan, apply, run a playbook.

## Repository Structure

```
.
├── provisioners/
│   ├── terraform-aws-modules/
│   │   ├── vpc/                  # VPC, IGW, public subnets, route tables
│   │   ├── instance/             # Security group + EC2 instance(s) + userdata
│   │   ├── providers.tf          # Injected into every stack by Terragrunt
│   │   └── variables.tf          # Global variables, injected by Terragrunt
│   └── ansible/
│       ├── playbooks/
│       │   ├── elasticsearch/es-node.yml     # Main playbook
│       │   ├── inventories/aws/.../aws_ec2.yml  # Dynamic AWS inventory
│       │   ├── es-smoke-test.sh              # End-to-end verification
│       │   └── ansible.cfg
│       └── roles/
│           ├── common/           # hostname, timezone, base packages
│           └── elasticsearch/    # install, sysctl, TLS check, vaulted password
└── resources/
    └── terraform/aws/
        ├── terragrunt.hcl        # Root config: state, providers, tfvars cascade
        ├── Makefile              # init / plan / apply / destroy wrapper
        ├── global.tfvars
        └── main/                                  # AWS account
            ├── account.tfvars
            └── ap-southeast-1/                    # Region
                ├── region.tfvars
                └── production/                    # Environment
                    ├── network.tfvars
                    ├── vpc/app/terragrunt.hcl     # VPC stack
                    └── instances/es-node/zone-a/terragrunt.hcl  # ES node stack
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) >= 0.50
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/index.html) >= 2.14, with collections:
  ```bash
  ansible-galaxy collection install amazon.aws ansible.posix
  pip install boto3 botocore
  ```
- AWS CLI configured with credentials (`aws configure`) for an account with EC2/VPC permissions
- An existing EC2 key pair in `ap-southeast-1` (referenced as `instance_key_name`)
- `yq` (used by the smoke-test script)

## Quick Start

### 1. Provision infrastructure (Terraform + Terragrunt)

All commands run from `resources/terraform/aws/` via the Makefile wrapper.

```bash
cd resources/terraform/aws

# 1a. Create the VPC
make init  dir=main/ap-southeast-1/production/vpc/app
make plan  dir=main/ap-southeast-1/production/vpc/app
make apply dir=main/ap-southeast-1/production/vpc/app

# 1b. Update the es-node stack inputs with the resulting vpc_id / subnet_id,
#     your AMI, and your key pair name:
#     main/ap-southeast-1/production/instances/es-node/zone-a/terragrunt.hcl

# 1c. Create the Elasticsearch instance
make init  dir=main/ap-southeast-1/production/instances/es-node/zone-a
make plan  dir=main/ap-southeast-1/production/instances/es-node/zone-a
make apply dir=main/ap-southeast-1/production/instances/es-node/zone-a
```

The instance is tagged with `hostgroup = es-node` and `environment = production` — these tags are what the Ansible dynamic inventory keys on.

### 2. Set the Elasticsearch password (Ansible Vault)

The `elastic` superuser password is stored encrypted with Ansible Vault in the inventory group vars:

```bash
cd provisioners/ansible/playbooks

# Encrypt your chosen password and place it under elastic_password in:
# inventories/aws/main/ap-southeast-1/production/group_vars/tag_Hostgroup_es_node
ansible-vault encrypt_string 'YourStrongPasswordHere' --name 'elastic_password'
```

### 3. Bootstrap Elasticsearch (Ansible)

```bash
cd provisioners/ansible/playbooks

# Verify the dynamic inventory can see the instance
ansible-inventory -i inventories/aws/main/ap-southeast-1/production/aws_ec2.yml --graph

# Run the playbook
ansible-playbook \
  -i inventories/aws/main/ap-southeast-1/production/aws_ec2.yml \
  elasticsearch/es-node.yml \
  --ask-vault-pass
```

The playbook is **idempotent** — safe to re-run. The one destructive step (resetting the `elastic` password) is guarded by a marker file (`/etc/elasticsearch/.password_configured`) and only runs once.

What the `elasticsearch` role does:

1. Installs ES 8.x from the official Elastic APT repository (GPG-verified)
2. Sets `vm.max_map_count` and fixes directory ownership
3. Templates `elasticsearch.yml` (security + TLS enabled) and JVM heap options
4. Starts the service and waits for port 9200
5. Verifies ES 8.x security auto-configuration generated the TLS certificates (`http.p12`, `transport.p12`) — fails loudly if not
6. Rotates the `elastic` password to the vaulted value (never logged, `no_log: true`)
7. Final check: authenticated HTTPS call to `/_cluster/health`

### 4. Verify (smoke test)

```bash
cd provisioners/ansible/playbooks

# Set ES_URL in es-smoke-test.sh to your instance's public IP first
./es-smoke-test.sh
```

The script proves, over **HTTPS with authentication**:

1. Connectivity (`You Know, for Search`)
2. Cluster health is not red
3. Document write
4. Document read
5. Search
6. Cleanup (deletes the test index)

Expected final output: `=== ALL CHECKS PASSED ===`

### 5. Teardown

```bash
cd resources/terraform/aws
make destroy dir=main/ap-southeast-1/production/instances/es-node/zone-a
make destroy dir=main/ap-southeast-1/production/vpc/app
```

## Security Model

| Layer | Mechanism |
|---|---|
| Authentication | `xpack.security.enabled: true`; `elastic` password rotated at bootstrap and stored in Ansible Vault — no plaintext secrets in the repo |
| Encryption in transit | TLS on HTTP (`http.p12`) and transport (`transport.p12`) layers via ES 8.x security auto-configuration |
| Network | Dedicated security group; SSH source CIDR parameterized (`ssh_allowed_cidr`) |
| Secrets hygiene | All password-handling tasks use `no_log: true`; vault-encrypted group vars |

**Demo-only exception:** port 9200 is publicly reachable (behind TLS + auth) so reviewers can run the smoke test. In production this node would live in a private subnet with the security group restricted to application CIDRs.

## Current Scope & Roadmap

- ✅ Single-node Elasticsearch with authentication and full TLS
- 🚧 Multi-node (3-node) cluster — in progress. The playbook is already parameterized for it: `discovery.seed_hosts` and `cluster.initial_master_nodes` are derived from the Ansible inventory group, and the Terraform module supports `instance_amount`. Remaining work is shared-CA transport certificate generation and distribution.

## Notes on AWS Free Tier

The stack uses only EC2, VPC, and EBS. The instance type is `t3.small` rather than the free-tier `t3.micro`: Elasticsearch 8.x with security enabled is not stable on 1 GB of RAM. This is disclosed per the exercise instructions; all other resources stay within free-tier limits.

## License

This repository was created solely as a technical assessment submission.