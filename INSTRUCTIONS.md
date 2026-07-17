# DKatalis Cloud Infrastructure Engineer — Technical Home Test

Repository: https://github.com/davidsugianto/dkatalis-infra-test

## 1. Solution Description

This repository provisions AWS EC2 instances and installs a **multi-node Elasticsearch 8.x cluster** (3 nodes by default) with security (authentication + TLS on both HTTP and transport layers, backed by a shared CA) enabled, fully automated end to end. The workflow is split into two layers, mirroring how I structure infrastructure at work:

**Infrastructure layer — Terraform + Terragrunt.** Reusable Terraform modules live under `provisioners/terraform-aws-modules/` (a `vpc` module and an `instance` module), while environment-specific configuration lives under `resources/terraform/aws/` in a Terragrunt hierarchy (`account -> region -> environment -> stack`). Variables cascade down through `global.tfvars`, `account.tfvars`, `region.tfvars`, and `network.tfvars`, so adding a new instance group is just a matter of creating a new small `terragrunt.hcl` file and running `terragrunt plan` / `terragrunt apply` with the target directory. The es-node stack launches `instance_amount = 3` identical instances behind one security group (ports 9200 HTTP and 9300 transport); cluster size is a single variable. A Makefile wraps the Terragrunt commands for consistency.

**Configuration layer — Ansible.** Once the instances are up, an Ansible playbook (`es-node.yml`) configures all of them in one run. Hosts are discovered dynamically through the `amazon.aws.aws_ec2` inventory plugin, keyed on the `hostgroup` EC2 tag that Terraform assigns — no static inventory files to maintain, so scaling the cluster is purely a Terraform change. The playbook applies two roles:

- `common`: hostname, timezone, base packages.
- `elasticsearch`: installs ES 8.x from the official Elastic APT repository (GPG-verified), sets `vm.max_map_count` and file-descriptor limits, fixes directory ownership, then handles cluster TLS: on the **first node only** (`run_once` + delegation) it generates a shared CA with `elasticsearch-certutil ca` and one CA-signed PKCS#12 certificate per node (SANs cover each node's private/public IPs, hostname, and private DNS name), fetches the bundle to the control node, and distributes each node's own certificate plus its vaulted keystore password to every host. It then templates `elasticsearch.yml` (security enabled, TLS on both HTTP and transport; `discovery.seed_hosts` and `cluster.initial_master_nodes` derived from the inventory group) and JVM heap options, starts the service, and rotates the `elastic` user password — once, on the first node — to a value stored in Ansible Vault. The password step is idempotent (guarded by a marker file plus a live authentication check) so re-runs are safe. The final task waits on `/_cluster/health?wait_for_nodes=N` to prove every node actually joined the cluster.

**Verification.** A smoke-test script (`es-smoke-test.sh`) proves the cluster works end to end over HTTPS with authentication against any node: connectivity check, cluster health, document write, read, search, and cleanup.

**Why this design:** I wanted the repo to look like real production infrastructure, not a one-off script. The monorepo separation between reusable modules (`provisioners/`) and live configuration (`resources/`) means future automation — new services, new regions, new environments — is plug-and-play: add a Terragrunt file, plan, apply, run the playbook.

### Current scope and limitations

- The implementation supports a **multi-node** Elasticsearch cluster (3 nodes by default, driven by the Terraform `instance_amount` variable). Cluster topology is never hardcoded: `discovery.seed_hosts`, `cluster.initial_master_nodes`, the certificate SAN list, and the final `wait_for_nodes` health check are all derived from the Ansible dynamic inventory group.
- All nodes currently launch in a single subnet/AZ; spreading them across AZs is the natural next step (the VPC module already creates multiple public subnets).
- The instance type is `t3.small` rather than the free-tier `t3.micro`. This is a deliberate deviation: Elasticsearch 8.x with security enabled is not stable on 1 GB of RAM. I am disclosing this per the instructions — and the default 3-node cluster multiplies EC2/EBS cost accordingly (`instance_amount = 1` remains supported for the cheapest run). Everything else (VPC, subnets, EBS volumes) stays within free-tier limits, and the smallest usable heap is configured to keep cost minimal.

## 2. Resources Consulted

- Elastic official docs: [Install Elasticsearch with Debian package](https://www.elastic.co/guide/en/elasticsearch/reference/current/deb.html), [Set up basic security (elasticsearch-certutil)](https://www.elastic.co/guide/en/elasticsearch/reference/current/security-basic-setup.html), [Discovery and cluster formation settings](https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-discovery-settings.html), [elasticsearch-reset-password](https://www.elastic.co/guide/en/elasticsearch/reference/current/reset-password.html)
- Terragrunt docs: [Keep your Terraform code DRY](https://terragrunt.gruntwork.io/docs/features/keep-your-terraform-code-dry/)
- Ansible docs: [amazon.aws.aws_ec2 dynamic inventory plugin](https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ec2_inventory.html), [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html)
- AWS docs: free-tier limits for EC2 and EBS

## 3. Time Spent & Feedback

- Time spent: **~2.5 days** on the core exercise (infrastructure + Elasticsearch role + smoke test).
- Feedback: the exercise is well scoped — it is small enough to finish in the time box but leaves clear room to demonstrate production thinking (security, structure, extensibility). The trade-off questions at the end are a good prompt for honest discussion. One suggestion: clarify whether "free tier" is a hard constraint, since ES 8.x with security enabled realistically needs more than 1 GB of RAM.

## 4. Additional Services Used

Only EC2, VPC, and EBS. No managed services (no Amazon OpenSearch Service, no ALB, no Secrets Manager) were used. The only deviation from free tier is the `t3.small` instance type, explained above.

---

# Answers to the Questions

## Q1. What did you choose to automate the provisioning and bootstrapping of the instance? Why?

**Terraform + Terragrunt for provisioning, Ansible for bootstrapping.**

I chose Terraform because declarative, stateful IaC gives me a reviewable plan before any change and a reliable `destroy` after the exercise — important both in production and when working against a personal AWS bill. I added Terragrunt on top to keep the Terraform code DRY: modules are written once under `provisioners/terraform-aws-modules/`, and each environment/region/stack only declares its inputs. This is the same layout I use professionally, and it directly answers "what if we add more infrastructure later?" — you add a folder, not copy-pasted HCL.

For bootstrapping I deliberately used Ansible instead of stuffing everything into `user_data`. Cloud-init scripts are fire-and-forget: they run once, are hard to debug, and cannot be re-applied. Ansible gives me idempotency (I can re-run the playbook safely — the password rotation is guarded by a marker file), readable diffs of what changed, and a natural place to keep secrets (Ansible Vault). The dynamic AWS EC2 inventory ties the two layers together: Terraform tags every instance with `hostgroup = es-node`, and Ansible targets `tag_Hostgroup_es_node` automatically, so there is no manually maintained inventory to drift — and scaling the cluster is a one-variable Terraform change that Ansible follows automatically.

## Q2. How did you choose to secure Elasticsearch? Why?

Three layers:

1. **Authentication.** `xpack.security.enabled: true`, so every request requires credentials. The `elastic` superuser password is rotated non-interactively at bootstrap (`elasticsearch-reset-password`, run once on the first node, output never logged via `no_log`) and then set to a value stored encrypted in **Ansible Vault** — no plaintext secrets in the repo or in shell history.
2. **Encryption in transit.** TLS is enabled on both the HTTP layer and the transport layer using a **shared cluster CA**: the playbook generates the CA with `elasticsearch-certutil ca` on the first node, issues one CA-signed PKCS#12 certificate per node (SANs covering each node's IPs and hostnames), and distributes them via Ansible before cluster formation. Transport TLS is strict — `client_authentication: required` with certificate verification — so only nodes holding a certificate signed by the cluster CA can join. The certificate password itself is stored in Ansible Vault (`elastic_cert_password`) and injected into the ES keystore, never written to config files.
3. **Network controls.** A dedicated security group restricts inbound traffic to SSH plus ports 9200/9300. The SSH source CIDR is parameterized (`ssh_allowed_cidr`) so it can be locked to an office/VPN range per environment.

Honest limitation: for the demo, port 9200 is reachable from the internet (protected by TLS + auth) so the reviewer can run the smoke test, and 9300 is likewise open rather than restricted to the security group itself. In production I would place the nodes in a private subnet, front them with a load balancer or restrict the SG to application CIDRs, lock 9300 to intra-SG traffic, and never expose either port publicly.

## Q3. How would you monitor this instance? What metrics would you monitor?

I would run a **Prometheus + Grafana** stack (my day-to-day tooling): `node_exporter` for host metrics and `elasticsearch_exporter` for cluster metrics, with Alertmanager for paging. On AWS, CloudWatch covers the hypervisor-level basics (CPU, status checks) for free.

Metrics I would watch, in priority order:

- **Cluster health:** status (green/yellow/red), number of nodes, unassigned shards — the primary paging signal.
- **JVM:** heap usage percentage and GC pause time/frequency. ES lives and dies by its heap; sustained heap above ~85% predicts instability before it happens.
- **Host:** disk usage on `/var/lib/elasticsearch` (ES stops allocating shards at flood-stage watermark, so alert well before 85%), CPU, memory, disk I/O latency.
- **Workload:** indexing and search rate, query latency percentiles, thread-pool rejections (rejections are the earliest sign the node is undersized).
- **Availability:** a blackbox HTTPS probe against `/_cluster/health` with authentication — effectively an automated version of my smoke test — which also validates that TLS and credentials keep working.

## Q4. Could you extend your solution to launch a secure cluster of 3 ElasticSearch nodes? What would need to change?

**This is implemented — the repository launches a secure 3-node cluster by default.** What it took, concretely:

1. **Terraform:** the `instance` module supports `instance_amount`; the es-node stack sets it to 3 and opens the transport port (9300) alongside 9200 in the security group. Every instance carries the same `hostgroup` tag, so the Ansible dynamic inventory picks all of them up automatically.
2. **Ansible cluster formation:** `discovery.seed_hosts` and `cluster.initial_master_nodes` are derived from the inventory group, all three master-eligible nodes start together, and the final health check waits on `wait_for_nodes=N` to prove the cluster actually formed. After the first successful formation, setting `es_cluster_bootstrapped: true` removes `cluster.initial_master_nodes` from the rendered config, per Elastic's guidance.
3. **Certificates — this was the real work:** ES auto-configuration generates per-node self-signed certs, which do not allow nodes to trust each other. Instead, the role generates a shared CA with `elasticsearch-certutil ca` on the first node (`run_once` + delegation), renders an `instances.yml` covering every node's IPs and hostnames, issues per-node CA-signed PKCS#12 certificates, fetches the bundle to the control node, and distributes each node's own certificate before cluster formation. Transport TLS requires client certificate authentication, so only CA-signed members can join. A tagged task (`es_certs_force`) allows forcing regeneration after topology changes.
4. **Secrets:** the certificate password (`elastic_cert_password`) is handled through Ansible Vault and injected into the ES keystore, same pattern as the `elastic` password; cert/key material is gitignored.

Remaining refinements: spread the nodes across AZs (the VPC module already creates multiple public subnets) and restrict 9300 to intra-security-group traffic.

## Q5. Could you extend your solution to replace a running ElasticSearch instance with little or no downtime? How?

Yes — with the 3-node cluster now in place, this is a standard rolling replacement rather than a theoretical exercise:

- **Cluster (little/no downtime):** with the 3-node cluster and at least 1 replica per index, do a rolling replacement: disable shard allocation, stop one node, bring up its replacement via Terraform + Ansible (the dynamic inventory picks it up automatically, and the shared-CA cert generation covers the new node — re-run the cert tasks with `es_certs_force` so its certificate is issued and distributed), let it join, re-enable allocation, wait for green, repeat. Clients keep working because the other two nodes serve traffic throughout. This is standard rolling-upgrade procedure, and the automation layers here (immutable instances from a module + idempotent playbook) are exactly what makes it repeatable.
- **If running single-node (`instance_amount = 1`):** zero downtime is impossible by definition. Minimize it instead: snapshot to S3, provision the replacement with the same Terraform module + playbook, restore, switch DNS/endpoint. Downtime is the cutover window.

## Q6. Was it a priority to make your code well structured, extensible, and reusable?

Yes — arguably the main priority after correctness, and it shaped the biggest decisions:

- **Monorepo with clear separation:** `provisioners/` holds reusable things (Terraform modules, Ansible roles), `resources/` holds live environment configuration. Adding new automation is plug-and-play: create a Terragrunt file, plan, apply, run a playbook.
- **Parameterization over hardcoding:** instance count, type, ports, CIDRs, ES version, cluster name, node roles, and seed hosts are all variables; the cluster-topology values (seed hosts, initial masters, certificate SANs, expected node count) come from inventory, not literals — which is what made going from one node to three a configuration change rather than a rewrite.
- **Idempotency:** the whole playbook can be re-run safely across the entire cluster; the destructive step (password reset) is explicitly guarded, and one-time cluster-level work (CA/cert generation, password bootstrap) uses `run_once` with delegation to the first node.
- **Roles over monolith:** `common` vs `elasticsearch` roles so the base-OS setup is reusable for any future service in the same repo.

## Q7. What sacrifices did you make due to time?

Being explicit about the trade-offs:

1. **All nodes in one subnet/AZ.** The 3-node cluster is implemented, but the nodes share a single public subnet; spreading them across AZs (which the VPC module already supports) was left out of the time box.
2. **ES ports exposed publicly for the demo.** 9200 is protected by TLS + authentication and 9300 by mutual-TLS transport, but in production the nodes would sit in a private subnet with 9200 restricted to application CIDRs and 9300 restricted to the security group itself.
3. **Local Terraform state** instead of an S3 + DynamoDB remote backend — fine for a solo exercise, not for a team.
4. **Cluster-internal CA rather than a publicly trusted one.** The shared CA gives SAN-correct, mutually verified certs inside the cluster, but external clients don't trust it — hence `validate_certs: false` / `curl -k` in the health checks and smoke test. In production I would either distribute the CA cert to clients or terminate client-facing TLS with a certificate from a real PKI.
5. **No monitoring stack deployed** — described in Q3 but not shipped, to stay inside the time box.
6. **`t3.small` over free-tier `t3.micro`** — ES 8.x with security enabled is not reliable on 1 GB RAM; I chose a working demo over strict free-tier compliance and am disclosing it here (and the 3-node default multiplies the cost — `instance_amount = 1` is still supported for the cheapest run).