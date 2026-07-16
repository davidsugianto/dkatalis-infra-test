# DKatalis Cloud Infrastructure Engineer — Technical Home Test

Repository: https://github.com/davidsugianto/dkatalis-infra-test

## 1. Solution Description

This repository provisions an AWS EC2 instance and installs Elasticsearch 8.x with security (authentication + TLS) enabled, fully automated end to end. The workflow is split into two layers, mirroring how I structure infrastructure at work:

**Infrastructure layer — Terraform + Terragrunt.** Reusable Terraform modules live under `provisioners/terraform-aws-modules/` (a `vpc` module and an `instance` module), while environment-specific configuration lives under `resources/terraform/aws/` in a Terragrunt hierarchy (`account -> region -> environment -> stack`). Variables cascade down through `global.tfvars`, `account.tfvars`, `region.tfvars`, and `network.tfvars`, so adding a new instance group is just a matter of creating a new small `terragrunt.hcl` file and running `make plan` / `make apply` with the target directory. A Makefile wraps the Terragrunt commands for consistency.

**Configuration layer — Ansible.** Once the instance is up, an Ansible playbook (`es-node.yml`) configures it. Hosts are discovered dynamically through the `amazon.aws.aws_ec2` inventory plugin, keyed on the `hostgroup` EC2 tag that Terraform assigns — no static inventory files to maintain. The playbook applies two roles:

- `common`: hostname, timezone, base packages.
- `elasticsearch`: installs ES 8.x from the official Elastic APT repository (GPG-verified), sets `vm.max_map_count`, fixes directory ownership, templates `elasticsearch.yml` and JVM heap options, starts the service, verifies that ES 8.x auto-configuration generated the TLS certificates (`http.p12`, `transport.p12`), and then rotates the `elastic` user password to a value stored in Ansible Vault. The password step is idempotent (guarded by a marker file) so re-runs are safe.

**Verification.** A smoke-test script (`es-smoke-test.sh`) proves the cluster works end to end over HTTPS with authentication: connectivity check, cluster health, document write, read, search, and cleanup.

**Why this design:** I wanted the repo to look like real production infrastructure, not a one-off script. The monorepo separation between reusable modules (`provisioners/`) and live configuration (`resources/`) means future automation — new services, new regions, new environments — is plug-and-play: add a Terragrunt file, plan, apply, run the playbook.

### Current scope and limitations

- The current implementation supports a **single-node** Elasticsearch cluster. Multi-node (3-node) support is in progress; the playbook is already parameterized for it — `discovery.seed_hosts` and `cluster.initial_master_nodes` are derived from the Ansible inventory group rather than hardcoded, so scaling is mostly a Terraform `instance_amount` change plus transport-certificate distribution (see Q4).
- The instance type is `t3.small` rather than the free-tier `t3.micro`. This is a deliberate deviation: Elasticsearch 8.x with security enabled is not stable on 1 GB of RAM. I am disclosing this per the instructions; everything else (VPC, subnets, EBS volume within 30 GB) stays within free-tier limits, and the smallest usable heap is configured to keep cost minimal.

## 2. Resources Consulted

- Elastic official docs: [Install Elasticsearch with Debian package](https://www.elastic.co/guide/en/elasticsearch/reference/current/deb.html), [Security auto-configuration](https://www.elastic.co/guide/en/elasticsearch/reference/current/configuring-stack-security.html), [elasticsearch-reset-password](https://www.elastic.co/guide/en/elasticsearch/reference/current/reset-password.html)
- Terragrunt docs: [Keep your Terraform code DRY](https://terragrunt.gruntwork.io/docs/features/keep-your-terraform-code-dry/)
- Ansible docs: [amazon.aws.aws_ec2 dynamic inventory plugin](https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ec2_inventory.html), [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html)
- AWS docs: free-tier limits for EC2 and EBS

## 3. Time Spent & Feedback

- Time spent: **~2.5 hours** on the core exercise (infrastructure + Elasticsearch role + smoke test). <!-- adjust to your actual number -->
- Feedback: the exercise is well scoped — it is small enough to finish in the time box but leaves clear room to demonstrate production thinking (security, structure, extensibility). The trade-off questions at the end are a good prompt for honest discussion. One suggestion: clarify whether "free tier" is a hard constraint, since ES 8.x with security enabled realistically needs more than 1 GB of RAM.

## 4. Additional Services Used

Only EC2, VPC, and EBS. No managed services (no Amazon OpenSearch Service, no ALB, no Secrets Manager) were used. The only deviation from free tier is the `t3.small` instance type, explained above.

---

# Answers to the Questions

## Q1. What did you choose to automate the provisioning and bootstrapping of the instance? Why?

**Terraform + Terragrunt for provisioning, Ansible for bootstrapping.**

I chose Terraform because declarative, stateful IaC gives me a reviewable plan before any change and a reliable `destroy` after the exercise — important both in production and when working against a personal AWS bill. I added Terragrunt on top to keep the Terraform code DRY: modules are written once under `provisioners/terraform-aws-modules/`, and each environment/region/stack only declares its inputs. This is the same layout I use professionally, and it directly answers "what if we add more infrastructure later?" — you add a folder, not copy-pasted HCL.

For bootstrapping I deliberately used Ansible instead of stuffing everything into `user_data`. Cloud-init scripts are fire-and-forget: they run once, are hard to debug, and cannot be re-applied. Ansible gives me idempotency (I can re-run the playbook safely — the password rotation is guarded by a marker file), readable diffs of what changed, and a natural place to keep secrets (Ansible Vault). The dynamic AWS EC2 inventory ties the two layers together: Terraform tags the instance with `hostgroup = es-node`, and Ansible targets `tag_Hostgroup_es_node` automatically, so there is no manually maintained inventory to drift.

## Q2. How did you choose to secure Elasticsearch? Why?

Three layers:

1. **Authentication.** `xpack.security.enabled: true`, so every request requires credentials. The `elastic` superuser password is rotated non-interactively at bootstrap (`elasticsearch-reset-password -b -s`, output never logged via `no_log`) and then set to a value stored encrypted in **Ansible Vault** — no plaintext secrets in the repo or in shell history.
2. **Encryption in transit.** TLS is enabled on both the HTTP layer (`http.p12`) and the transport layer (`transport.p12`), using the certificates that ES 8.x security auto-configuration generates on first boot. The playbook explicitly verifies the certs exist and fails loudly if auto-configuration did not run. I chose auto-configuration over a hand-rolled CA because within the time box it gives correct, full-stack TLS with the least custom code; for a multi-node cluster I would generate a shared CA with `elasticsearch-certutil` instead (see Q4).
3. **Network controls.** A dedicated security group restricts inbound traffic to SSH and port 9200. The SSH source CIDR is parameterized (`ssh_allowed_cidr`) so it can be locked to an office/VPN range per environment.

Honest limitation: for the demo, port 9200 is reachable from the internet (protected by TLS + auth) so the reviewer can run the smoke test. In production I would place the node in a private subnet, front it with a load balancer or restrict the SG to application CIDRs, and never expose 9200 publicly.

## Q3. How would you monitor this instance? What metrics would you monitor?

I would run a **Prometheus + Grafana** stack (my day-to-day tooling): `node_exporter` for host metrics and `elasticsearch_exporter` for cluster metrics, with Alertmanager for paging. On AWS, CloudWatch covers the hypervisor-level basics (CPU, status checks) for free.

Metrics I would watch, in priority order:

- **Cluster health:** status (green/yellow/red), number of nodes, unassigned shards — the primary paging signal.
- **JVM:** heap usage percentage and GC pause time/frequency. ES lives and dies by its heap; sustained heap above ~85% predicts instability before it happens.
- **Host:** disk usage on `/var/lib/elasticsearch` (ES stops allocating shards at flood-stage watermark, so alert well before 85%), CPU, memory, disk I/O latency.
- **Workload:** indexing and search rate, query latency percentiles, thread-pool rejections (rejections are the earliest sign the node is undersized).
- **Availability:** a blackbox HTTPS probe against `/_cluster/health` with authentication — effectively an automated version of my smoke test — which also validates that TLS and credentials keep working.

## Q4. Could you extend your solution to launch a secure cluster of 3 ElasticSearch nodes? What would need to change?

Yes — the code was written with this in mind, and it is the in-progress next step. Concretely:

1. **Terraform:** the `instance` module already supports `instance_amount`; change it from 1 to 3 and spread nodes across subnets/AZs (the VPC module already creates multiple public subnets). Add a security-group rule for the transport port (9300) restricted to the security group itself, so only cluster members can talk transport.
2. **Ansible:** the playbook already derives `discovery.seed_hosts` and `cluster.initial_master_nodes` from the inventory group, so the config templating needs no change.
3. **Certificates — the real work:** ES auto-configuration generates per-node self-signed certs, which will not allow nodes to trust each other. I would generate a shared CA with `elasticsearch-certutil ca` on the first node (or locally), issue per-node transport certificates signed by that CA, and distribute them via Ansible before first start. Cluster bootstrap must also be ordered: bring up the first master-eligible node, then join the others (or set all three in `initial_master_nodes` and start them together).
4. **Secrets:** node enrollment/CA material handled through Ansible Vault, same pattern as the `elastic` password.

## Q5. Could you extend your solution to replace a running ElasticSearch instance with little or no downtime? How?

With the current single node, zero downtime is impossible by definition — one node means one point of failure. Realistic options:

- **Single node (minimize downtime):** snapshot to S3, provision the replacement with the same Terraform module + playbook, restore, switch DNS/endpoint. Downtime is the cutover window.
- **Cluster (little/no downtime) — the proper answer:** with the 3-node cluster from Q4 and at least 1 replica per index, do a rolling replacement: disable shard allocation, stop one node, bring up its replacement via Terraform + Ansible (the dynamic inventory picks it up automatically), let it join, re-enable allocation, wait for green, repeat. Clients keep working because the other two nodes serve traffic throughout. This is standard rolling-upgrade procedure, and the automation layers here (immutable instances from a module + idempotent playbook) are exactly what makes it repeatable.

## Q6. Was it a priority to make your code well structured, extensible, and reusable?

Yes — arguably the main priority after correctness, and it shaped the biggest decisions:

- **Monorepo with clear separation:** `provisioners/` holds reusable things (Terraform modules, Ansible roles), `resources/` holds live environment configuration. Adding new automation is plug-and-play: create a Terragrunt file, plan, apply, run a playbook.
- **Parameterization over hardcoding:** instance count, type, ports, CIDRs, ES version, cluster name, and seed hosts are all variables; the cluster-topology values come from inventory, not literals.
- **Idempotency:** the whole playbook can be re-run safely; the destructive step (password reset) is explicitly guarded.
- **Roles over monolith:** `common` vs `elasticsearch` roles so the base-OS setup is reusable for any future service in the same repo.

## Q7. What sacrifices did you make due to time?

Being explicit about the trade-offs:

1. **Single node instead of the 3-node bonus.** The cluster path requires shared-CA certificate distribution done properly; I preferred a solid, verified single node over a rushed cluster. The code is parameterized so the extension is incremental, and multi-node support is actively in progress.
2. **ES port exposed publicly for the demo.** Protected by TLS + authentication, but in production it would sit in a private subnet behind restricted security groups.
3. **Local Terraform state** instead of an S3 + DynamoDB remote backend — fine for a solo exercise, not for a team.
4. **ES auto-generated certificates** instead of a proper internal CA with SAN-correct, verifiable certs (hence `validate_certs: false` / `curl -k` in the checks).
5. **No monitoring stack deployed** — described in Q3 but not shipped, to stay inside the time box.
6. **`t3.small` over free-tier `t3.micro`** — ES 8.x with security enabled is not reliable on 1 GB RAM; I chose a working demo over strict free-tier compliance and am disclosing it here.