# dkatalis-infra-test

A Technical Home Test for the DKatalis Cloud Infrastructure Engineer position.

This repository provisions AWS EC2 instances with **Terraform + Terragrunt** and bootstraps a secured **multi-node Elasticsearch 8.x cluster** (3 nodes by default — authentication + TLS on both HTTP and transport layers, backed by a shared CA) with **Ansible**. A smoke-test script verifies the cluster works end to end over HTTPS with credentials.

> Full solution write-up, design decisions, and answers to the exercise questions: see [INSTRUCTIONS.md](./INSTRUCTIONS.md).

## Architecture Overview

```
Terraform/Terragrunt                     Ansible
┌─────────────────────────┐   tags      ┌──────────────────────────────┐
│ vpc module              │  hostgroup  │ aws_ec2 dynamic inventory    │
│  VPC, IGW, subnets, RT  │ ──────────► │  targets tag_Hostgroup_*     │
│ instance module         │             │ roles:                       │
│  SG + EC2 x N           │             │  common (base OS)            │
│  (+ userdata)           │             │  elasticsearch (install,     │
└─────────────────────────┘             │   shared-CA TLS, cluster     │
                                        │   formation, vaulted creds)  │
                                        └──────────────────────────────┘

Elasticsearch cluster (default: 3 nodes)
┌───────────────┐  transport 9300 (TLS)  ┌───────────────┐
│ es-node-0     │ ◄────────────────────► │ es-node-1     │
│ (cert gen +   │ ◄──────────┐           └───────────────┘
│  pwd bootstrap│            │  ┌───────────────┐
│  run here)    │            └► │ es-node-2     │
└───────────────┘               └───────────────┘
   All nodes: HTTPS 9200, per-node certs signed by one shared CA
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
│           └── elasticsearch/    # install, sysctl, shared-CA cert generation
│                                 #  + distribution, cluster formation,
│                                 #  vaulted passwords
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
                    └── instances/es-node/zone-a/terragrunt.hcl  # ES cluster stack
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
cd main/ap-southeast-1/production/vpc/app
terragrunt plan 
terragrunt apply -auto-approve

# 1b. Update the es-node stack inputs with the resulting vpc_id / subnet_id,
#     your AMI, your key pair name, and the desired cluster size
#     (instance_amount, default 3):
#     main/ap-southeast-1/production/instances/es-node/zone-a/terragrunt.hcl

# 1c. Create the Elasticsearch cluster nodes
cd main/ap-southeast-1/production/instances/es-node/zone-a
terragrunt plan 
terragrunt apply -auto-approve
```

The stack launches `instance_amount` EC2 instances (default **3**) behind one security group with ports 9200 (HTTP) and 9300 (transport) open. Every instance is tagged with `hostgroup = es-node` and `environment = production` — these tags are what the Ansible dynamic inventory keys on, so the cluster size is purely a Terraform variable: scale by changing `instance_amount`, no Ansible changes needed.

### 2. Set the Elasticsearch secrets (Ansible Vault)

Two secrets are stored encrypted with Ansible Vault in the inventory group vars (`inventories/aws/main/ap-southeast-1/production/group_vars/tag_Hostgroup_es_node`):

- `elastic_password` — the `elastic` superuser password
- `elastic_cert_password` — the password protecting the shared CA and the per-node PKCS#12 certificates

```bash
cd provisioners/ansible/playbooks

# Put your vault passphrase in the (gitignored) vault password file
# referenced by ansible.cfg:
echo 'YourVaultPassphrase' > ../files/credentials/vault_password_file

# Encrypt each secret and place it in the group_vars file:
ansible-vault encrypt_string 'YourStrongPasswordHere' --name 'elastic_password'
ansible-vault encrypt_string 'YourCertPasswordHere'   --name 'elastic_cert_password'
```

### 3. Bootstrap Elasticsearch (Ansible)

```bash
cd provisioners/ansible/playbooks

# Verify the dynamic inventory can see all cluster nodes
ansible-inventory -i inventories/aws/main/ap-southeast-1/production/aws_ec2.yml --graph

# Run the playbook against the whole cluster
ansible-playbook \
  -i inventories/aws/main/ap-southeast-1/production/aws_ec2.yml \
  elasticsearch/es-node.yml --diff
```

(The vault passphrase is read from the `vault_password_file` configured in `ansible.cfg`; pass `--ask-vault-pass` instead if you skipped that step.)

The playbook is **idempotent** — safe to re-run. The one destructive step (resetting the `elastic` password) runs once, on the first node only, guarded by a marker file (`/etc/elasticsearch/.elastic_password_set`) plus a live authentication check against the vaulted password.

What the `elasticsearch` role does, across all nodes:

1. Installs ES 8.x from the official Elastic APT repository (GPG-verified)
2. Sets `vm.max_map_count`, file-descriptor limits, and fixes directory ownership
3. **Generates cluster TLS certificates on the first node only** (`run_once` + delegation): a shared CA via `elasticsearch-certutil ca`, then one PKCS#12 certificate per node — with SANs covering each node's private/public IP, hostname, and private DNS name — signed by that CA
4. **Distributes the certificates**: fetches the cert bundle to the control node, unpacks each node's own certificate to `/etc/elasticsearch/certs/elastic-certificates.p12`, and stores the (vaulted) certificate password in the ES keystore
5. Templates `elasticsearch.yml` — security + TLS on both HTTP and transport layers, `discovery.seed_hosts` and `cluster.initial_master_nodes` derived from the inventory group (set `es_cluster_bootstrapped: true` after first successful formation to drop `initial_master_nodes`, per Elastic guidance) — and JVM heap options
6. Starts the service and waits for port 9200 on every node
7. Rotates the `elastic` password to the vaulted value — first node only, never logged (`no_log: true`)
8. Final check: authenticated HTTPS call to `/_cluster/health?wait_for_nodes=N`, confirming every node joined, then reports cluster name/status/node count

To force certificate regeneration (e.g. after changing cluster topology), re-run with `--tags es_certs_force,es_certs`.

### 4. Verify (smoke test)

```bash
cd provisioners/ansible/playbooks

# Set ES_URL in es-smoke-test.sh to any node's public IP first
./es-smoke-test.sh
```

The script proves, over **HTTPS with authentication** (against any node — writes are replicated across the cluster):

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
| Encryption in transit | TLS on both HTTP (9200) and transport (9300) layers, using per-node certificates signed by a **shared cluster CA** (`elasticsearch-certutil`); transport enforces `client_authentication: required` with certificate verification, so only cluster members holding a CA-signed cert can join |
| Network | Dedicated security group; SSH source CIDR parameterized (`ssh_allowed_cidr`) |
| Secrets hygiene | All password-handling tasks use `no_log: true`; vault-encrypted group vars (`elastic_password`, `elastic_cert_password`); certificate/key material is gitignored |

**Demo-only exception:** ports 9200/9300 are publicly reachable (behind TLS + auth) so reviewers can run the smoke test. In production the nodes would live in a private subnet, with 9200 restricted to application CIDRs and 9300 restricted to the security group itself.

## Current Scope & Roadmap

- ✅ Multi-node (default 3-node) Elasticsearch cluster with authentication and full TLS via a shared CA
- ✅ Cluster size driven by a single Terraform variable (`instance_amount`) — seed hosts, initial masters, certificates, and health checks all derive from the dynamic inventory
- 🚧 Spread nodes across multiple AZs (currently all nodes share one subnet/zone)
- 🚧 Restrict transport port 9300 to the security group itself instead of a public CIDR

## Notes on AWS Free Tier

The stack uses only EC2, VPC, and EBS. The instance type is `t3.small` rather than the free-tier `t3.micro`: Elasticsearch 8.x with security enabled is not stable on 1 GB of RAM. Note that the default 3-node cluster also multiplies EC2/EBS cost by three; set `instance_amount = 1` for the cheapest possible run. This is disclosed per the exercise instructions; all other resources stay within free-tier limits.

## License

This repository was created solely as a technical assessment submission.