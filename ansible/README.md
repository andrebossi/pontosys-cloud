# Ansible

Configuration for the fleet. The application VMs are `VM.Standard.E4.Flex`,
**1 OCPU (2 vCPU) and 6 GB**, each running eight .NET processes behind a local
nginx — every ceiling in here follows from those two numbers.

```
inventory/oci.yml            dynamic inventory for the cloud, from the pscloud.* tags
inventory/local.yml          static inventory template for VMs on a workstation
group_vars/all.yml           every machine
group_vars/env_{local,rc,prod}.yml
group_vars/role_app/         the application VMs
group_vars/role_monitoring.yml
host_vars/<address>.yml      one machine
site.yml                     converge everything
deploy.yml                   install application versions
release.yml                  manifests: show, list, promote, rollback
image.yml                    the golden image, run by Packer
```

| Role | What it owns |
|---|---|
| `base` | accounts and sudo, timezone, sysctl, THP, I/O scheduler, swap, journald, firewall, OCI identity |
| `secrets` | credentials, from OCI Vault or a local file, generated on first use |
| `artifact` | fetch and unpack a bundle, from the bucket or a local directory |
| `dotnet_runtime` | the two .NET runtimes, OpenSSL compat, libgdiplus, fonts |
| `dotnet_app` | the systemd slice, unit template, drop-ins, config and secrets |
| `db_users` | one MySQL account per application, granted only its schemas |
| `nginx_app` | nginx from the official collection, routing, error pages, web root |
| `observability_agent` | Fluent Bit: unit logs, host metrics, per-app cgroup metrics |
| `app_deploy` | switch a release, health-check, roll back |
| `release` | the `pscloud` CLI: artifacts and manifests |
| `monitoring_stack` | Docker and the observability backend |

> `ansible/files/` is **reference material** — the old machine's document root
> and its font files, kept only so this repository could be written against
> what actually ran. Nothing in the roles reads it, and it does not ship. The
> fonts and the web root are artifacts now; see [Artifacts](#artifacts).

## Environments

Three, and the middle one is the unusual part.

| | machines | secrets | artifacts | versions |
|---|---|---|---|---|
| **local** | VMs on a workstation, static inventory | a 0600 file on the control node | a directory on the control node | newest available |
| **rc** | **real machines, in the production load balancer** | OCI Vault | the bucket | newest published |
| **prod** | the rest of the fleet | OCI Vault | the bucket | exactly what the manifest pins |

`rc` is not a copy of production. It is a **small number of the production
machines**, tagged `pscloud.environment = rc`, taking real traffic from the
same load balancer as everything else. A release goes there first, serves real
requests against the real database, and is watched. That is the test.

This is why `latest` is allowed in rc and forbidden in prod: rc chases the tip
and **records what it got** in a manifest; prod installs what promotion pinned.
Without the manifest, "what rc validated" and "what prod is about to install"
would be related only by hope.

Two variables do all of it, and nothing else in the repository knows the
difference:

```yaml
secrets_backend: oci | local
artifact_store:  bucket | local
```

## Testing locally

Three Ubuntu 24.04 VMs on a workstation. Everything below is the same code the
cloud runs — the two switches above are the whole difference.

### 1. The VMs

Two app machines and one for the monitoring stack. Any hypervisor; the
addresses just have to be reachable and stable.

```sh
for n in 10 11 12; do
  multipass launch 24.04 --name pscloud-$n --cpus 2 --memory 4G --disk 20G
done
```

Copy `inventory/local.yml`, put the real addresses in it, and make sure your
key is on each VM. Inventory hostnames are **addresses**, matching the OCI
plugin's `hostname_format: private_ip` — that is what lets `monitoring_host`
resolve identically in both places with no special case in any role.

### 2. MySQL

A container is enough:

```sh
docker run -d --name pscloud-mysql -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=localdev mysql:8.4

export PSCLOUD_DB_HOST=192.168.122.1     # reachable from the VMs, not 127.0.0.1
```

`group_vars/env_local.yml` sets `db_create_schemas: true` and widens
`db_user_host` to `%`, because a container is not on `10.20.0.0/16`.

### 3. Artifacts

`artifact_store: local` reads a directory instead of the bucket. The layout is
the same as the bucket's, so the same tarballs work in both:

```
~/pscloud-artifacts/
  pixapi/pixapi-1.10.0.tar.gz
  virtualstore/virtualstore-2.9.1.tar.gz
  fonts/fonts-1.tar.gz
  webroot/webroot-2026.09.12.tar.gz
```

The font bundle is the one you need before the first converge — `virtualstore`
and `relatoriosapi` set `drawing: true`, so the runtime role installs and
verifies the faces. Build it once from the reference copy:

```sh
mkdir -p ~/pscloud-artifacts/fonts
tar -C ansible/files/fontes -czf ~/pscloud-artifacts/fonts/fonts-1.tar.gz .
```

Applications are packed from *inside* the publish directory:

```sh
dotnet publish -c Release -o out
mkdir -p ~/pscloud-artifacts/pixapi
tar -C out -czf ~/pscloud-artifacts/pixapi/pixapi-1.10.0.tar.gz .
```

### 4. Converge

```sh
ansible-galaxy install -r requirements.yml

# first run: the accounts do not exist yet, so connect as the image's user
ansible-playbook -i inventory/local.yml site.yml -u ubuntu

# afterwards, as the deployment account roles/base created
ansible-playbook -i inventory/local.yml deploy.yml -u deploy
```

No `OCI_*` variables, no vault, no `pscloud` CLI. On the first run
`roles/secrets` generates every credential it needs and writes them to
`~/.pscloud/secrets-local.json`, mode 0600. Subsequent runs read that file
back, so the passwords are stable — **delete the file to rotate everything**.

That is what "the machine's credentials" means here: whatever this workstation
has already generated is what it keeps using. The one thing you have to
reconcile by hand is the MySQL admin password — either put the container's root
password into the file as `pscloud-local-db-admin` before the first run, or let
the run generate one and set it on the server to match.

### 5. Look at it

```sh
ssh deploy@192.168.122.11 'systemctl status "dotnet-app@*"'
curl http://192.168.122.11/healthz
xdg-open http://192.168.122.10:3000            # Grafana
```

### What local does not cover

Worth knowing before you trust a green run:

- **The instance metadata service.** `oci-instance-label.sh` falls back to
  `unknown` for every label, so metrics and logs arrive with no instance
  identity. Everything else works.
- **Pre-authenticated URLs.** Local copies files over the SSH connection; the
  cloud has the target fetch them itself over HTTP. Different code path in
  `roles/artifact`, same unpack.
- **The load balancer**, and therefore the whole rc-in-prod idea.
- **The golden image.** Packer needs OCI.

## Deploying to the cloud

Everything runs **from the monitoring VM**. It is the only host with a public
IP, it is the jump host into the private subnets, and — the part that matters —
its instance principal is the identity that reads OCI Vault and mints the
artifact download URLs. There is no key on disk anywhere.

```sh
ssh monitoring
cd /opt/pscloud/repo && git pull

export OCI_COMPARTMENT_OCID=ocid1.compartment.oc1..xxx
export OCI_VAULT_OCID=ocid1.vault.oc1..xxx          # terraform output vault_id
export OCI_VAULT_KEY_OCID=ocid1.key.oc1..xxx        # terraform output vault_key_id
export PSCLOUD_DB_HOST=10.20.32.5                   # terraform output mysql private_ip

ansible-inventory --graph                     # role_app, role_monitoring, env_rc, env_prod
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
```

`ansible.cfg` points at `inventory/oci.yml`, so no `-i`. Grouping comes from the
defined tags Terraform applies — the same tags that drive the IAM dynamic
groups, so network, identity and Ansible have one source of truth.

**From a laptop instead**, export `OCI_CLI_PROFILE` and `roles/secrets` uses the
API key in `~/.oci/config` rather than an instance principal. Same playbooks;
only the authentication changes.

## Rolling out

Manual, in steps, because each gap is a person deciding whether to continue.
The pipeline runs the commands; it does not decide.

```sh
# CI, on release published
tar -C out -czf pixapi.tar.gz .
pscloud push pixapi 1.10.0 ./pixapi.tar.gz
```

**1 — rc.** A handful of machines in the production load balancer. Real
traffic, one blast radius. The deploy records a manifest of exactly what
landed.

```sh
ansible-playbook deploy.yml -l env_rc
```

**2 — watch it.** Grafana, filtered to those instances. `5xx` rate, p95, and
the swap and pressure series described under [Observability](#observability).
No automatic gate: nothing here shifts traffic on a metric it read by itself.

**3 — promote.** Copies rc's app versions verbatim into prod's manifest. Not a
fresh resolution of `latest`, which could have moved since.

```sh
ansible-playbook release.yml -e release_action=promote \
                             -e release_from_env=rc -e release_to_env=prod
```

**4 — canary, then the rest.** One machine, look, then widen the batch. Each is
its own pipeline step.

```sh
echo 10.20.16.7 > canary.txt
ansible-playbook deploy.yml --limit-file canary.txt      # one machine
ansible-playbook deploy.yml -l env_prod -e deploy_serial=25%
```

`deploy_serial` defaults to 1: one VM at a time, the others still serving, and
a bad release stops at the first machine rather than all of them. Every deploy
health-checks the app on its own port after the symlink switch and rolls that
machine back — with the last 50 journal lines — if it does not answer.

**Rollback** is an older manifest:

```sh
ansible-playbook deploy.yml -l env_prod -e app_version_source=manifest \
                            -e app_manifest=2026.09.10-2
ansible-playbook release.yml -e release_action=rollback \
                             -e release_to_env=prod -e release_tag=2026.09.10-2-prod
```

### Two speeds

| | changes | delivered by | takes |
|---|---|---|---|
| **base** — OS, runtimes, nginx, agent, unit files | monthly | a baked image | ~10 min |
| **apps** — the `dotnet publish` trees | hourly | `deploy.yml` | ~30 s |

`packer/app.pkr.hcl` boots a stock Ubuntu, hands it to `ansible/image.yml`, and
captures the result — every decision about what goes on the machine lives in
Ansible. The image is a function of (this repository at a commit) + (prod's
manifest), never a snapshot of a machine that has served traffic.

Pointing an instance pool at a new image is **`app_image_id` in
`infra/live/<env>/app-tier`** — a reviewed Terraform change, not an API call
from a playbook. That is also why `pscloud` has no image subcommands: it is the
bucket and nothing else.

Build the image on two triggers, not one: a release published, *and* a push
touching `roles/{base,dotnet_runtime,nginx_app,observability_agent}/**` —
otherwise a runtime security patch waits for an unrelated app release.

## Accounts

Three, created by `roles/base`. Nothing logs in as root, and no application
runs as a human.

| | shell | sudo | for |
|---|---|---|---|
| `dotnetapp` | `nologin` | none | running the applications; owns `/srv/apps` |
| `deploy` | bash, key-only | full, `NOPASSWD` | automation — Ansible connects as this |
| `ops` | bash, key-only | a short allowlist | humans looking at a misbehaving machine |

The honest limit: **`deploy` has full sudo**, because Ansible's modules run as
root and a command allowlist that covers them is an allowlist for root.
Pretending otherwise would be theatre. What the separation buys is that
automation is its own keyed, non-interactive, password-locked account with its
own audit trail — not a shared login, and not `root`.

**`ops` is where the restriction is real.** Most of what it needs is group
membership rather than sudo at all: `systemd-journal` reads the journal, `adm`
reads `/var/log`, and an ACL gives it read access to `/srv/apps`. Its sudo
allowlist is short enough to read in one go — `systemctl status|cat|show`,
`journalctl`, `systemd-cgtop` — plus exactly one write:

```
ops ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart dotnet-app@*
```

Restarting a wedged application at 3am, and no other unit on the box. It cannot
touch nginx, sshd or the agent.

Public keys go in `base_users.<name>.ssh_keys`, in group_vars or host_vars.
They are not secrets, but they are site-specific, so the defaults are empty:

```yaml
base_users:
  ops:
    ssh_keys:
      - "ssh-ed25519 AAAA... andre"
```

`exclusive: true` on the key task means the list in the repository *is* the
list on the machine — removing someone here removes them on the next converge.

## Secrets

No `vault.yml`, no ansible-vault passphrase, nothing in git.

**In the cloud**, OCI Vault. Authentication follows the machine: on the
monitoring VM the instance principal is used and `infra/modules/identity`
grants the `monitoring` dynamic group `manage secret-family`, `use keys` and
`use vaults`. From a laptop, `OCI_CLI_PROFILE` selects an API key instead.

**Locally**, a 0600 JSON file on the control node.

Either way, two kinds of secret:

**Generated.** One database password per application, `app_<name>`. On the
first run it does not exist, so it is generated (32 characters), stored, and
used. Every run after reads it back. Rotating is deleting it and re-running —
nothing in this repository changes, because the username is derived and the
password is never written down here.

**Pre-existing.** Credentials shared with systems outside this fleet, listed in
`app_secret_refs` and only ever read:

```
pscloud-<env>-db-admin              the MySQL admin account
pscloud-<env>-smtp-password         virtualstore's SMTP password
pscloud-<env>-jwt-monitorclientes   the signing key monitorclientesapi issues
```

Create those once (the local backend generates them instead, since there is
nothing external to match):

```sh
oci vault secret create-base64 --compartment-id "$OCI_COMPARTMENT_OCID" \
    --vault-id "$OCI_VAULT_OCID" --key-id "$OCI_VAULT_KEY_OCID" \
    --secret-name pscloud-prod-smtp-password \
    --secret-content-content "$(printf %s 'the password' | base64)"
```

Values land in `/etc/dotnet-apps/<app>.env` (0640 root:dotnetapp) as environment
variables, which outrank every JSON file in .NET configuration. They are not in
the artifact, not in the image, and not in `systemctl show`.

> The `appsettings.json` copies under `files/nginx/nginx-config/` contain
> **live** database, SMTP and JWT credentials. They are not in git history and
> `.gitignore` keeps them out. The values they hold are exactly what the vault
> entries above replace, so **rotate them** once the fleet is on the new
> accounts.

## Artifacts

One store, one layout, four kinds of thing in it:

```
artifacts/<app>/<app>-<version>.tar.gz       the dotnet publish trees
artifacts/fonts/fonts-<version>.tar.gz       the report faces
artifacts/webroot/webroot-<version>.tar.gz   the SPA bundles and error pages
manifests/<env>/{current,<release>}.json     what each environment runs
```

`roles/artifact` is the only thing that knows how to fetch one, which is why
`artifact_store: local` needed implementing in exactly one place for apps,
fonts and the web root alike.

In the cloud a machine downloads through a **pre-authenticated URL minted by
the release host**, so an autoscaled VM needs no credential of its own and the
bytes go over the service gateway instead of the NAT gateway. There is no path
that pulls from GitHub.

Fonts and the web root are versioned and pinnable like anything else:

```yaml
fonts_version: latest        # or "1"
webroot_version: latest      # or "2026.09.12"
```

## Where a change goes

Almost everything is a dictionary edit. If it is true for the whole role it
belongs in `group_vars/role_*`; if it is true for one machine, in `host_vars/`.
There is no `when: role == ...` anywhere in the tasks.

| I want to change | File |
|---|---|
| add or remove an application | `group_vars/role_app/applications.yml` |
| what an application may spend | `app_tiers` in `platform.yml` |
| a runtime, a font, an nginx timeout | `platform.yml` |
| an appsettings value, a database, a secret | `config.yml` |
| a new Fluent Bit collection | `observability.yml` |
| the VM shape | `host_vcpus` / `host_memory_mb` in `all.yml` |
| accounts, sudo, kernel tuning, swap | `roles/base/defaults/main.yml` |
| the monitoring stack's budget | `group_vars/role_monitoring.yml` |

### Adding an application

One entry in `group_vars/role_app/applications.yml`:

```yaml
  novaapi:
    description: Nova API
    dll: Nova.Api.dll
    port: 5009
    path: /novaapi
    tier: api
    connections:
      NovaContext: global
```

That produces the systemd unit and its drop-ins, the nginx upstream and
`location`, the database account and grant, the generated password, the env
file, the appsettings overlay, the `app` label on every log line and request
metric, and the deploy target. No role, task or template changes.

Optional keys: `runtime` picks a .NET version (default 5.0), `drawing: true`
pulls in libgdiplus and the fonts, `linked_dirs` lists directories holding
state that must survive a release, `db_privileges` narrows a grant.

## Database accounts

One MySQL account per application — `app_<name>` — granted only on the schemas
that application's `connections` reference. It replaces two shared logins:
`glb_user` was used by four applications and `cep_user` by three, so a leaked
connection string from the reports API opened the sales database for writing.

**The schemas do not have to exist.** MySQL accepts a grant on a database that
is not there yet, so the accounts can be in place long before any data is —
segregate first, migrate later.

```
app_virtualstore          cep.*:SELECT / virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE,EXECUTE
app_monitorclientesapi    virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE,EXECUTE
app_geradorrelatoriosapi  virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE,EXECUTE
app_cadastrosapi          cep.*:SELECT
app_entradaapi            cep.*:SELECT / virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE,EXECUTE
```

`cep` is read-only for everyone — it is a postal-code reference set loaded out
of band. `DROP`, `ALTER` and `CREATE` are absent everywhere: a schema change is
a migration, run deliberately, not something an API can do by accident.

```sh
ansible-playbook site.yml --tags db
```

It runs from an application VM (`run_once`), because the NSG only lets the app
tier reach the database on 3306. Resolution is most-specific-first:
`applications[app].db_privileges[server]` → `db_servers[server].privileges` →
`db_privileges_default`.

Two things worth knowing. Accounts use **`caching_sha2_password`**, MySQL 8's
default and the only option on 8.4+. The module gives `password:` precedence
over `plugin:` and would silently produce a native-password account, so the
role sets `plugin` + `plugin_auth_string` + `salt` instead — the salt is what
keeps it idempotent. That plugin cannot complete a handshake over a plaintext
connection unless the client fetches the server's public key, which is why
`AllowPublicKeyRetrieval=True` is in `db_connection_options`; it sends the
password RSA-encrypted rather than in the clear. **Enabling TLS on the DB
system and moving to `SslMode=Required` is the better end state.**

## The host

`roles/base` owns everything about the machine underneath the applications.
Terraform passes **no `user_data`**: a cloud-init copy of this would be a second
definition to keep in step, and it would only ever run on first boot.

- **`vm.overcommit_memory=1`** — a .NET process reserves far more address space
  than it touches, and strict accounting refuses the reservation.
- **`vm.max_map_count=262144`** — eight runtimes each mapping hundreds of
  assemblies reach the 65530 default long before they reach a memory limit.
- **BBR + fq**, `tcp_slow_start_after_idle=0` — the upstreams are keepalive and
  idle between bursts; without this the kernel resets the congestion window on
  every gap and the first request pays for it.
- **THP on `madvise`** — `always` hands out 2 MB pages the GC did not ask for,
  which on a 6 GB box inflates the resident set and stalls on compaction.
- **No guest I/O scheduler** on the boot volume: it is paravirtualised and
  already queues on the hypervisor side.
- **Swap, 2 GB, swappiness 10** — not there to run from. It is there so a GC
  spike is paged out instead of tripping the OOM killer, and `MemorySwapMax`
  per app keeps any one of them from living in it.
- **The firewall**, which is the one thing cloud-init did that had to move
  somewhere: `base_open_ports` inserts the ACCEPT rules ahead of the REJECT the
  OCI Ubuntu image ships, and persists them.

**Architecture.** The OCI application VMs are x86_64 and the monitoring machine
is arm64, so everything architecture-specific derives from `ansible_architecture`
rather than being assumed: the .NET runtime tarball (`linux-x64` /
`linux-arm64`), the OpenSSL 1.1 `.deb` (which lives on `security.ubuntu.com` for
amd64 and `ports.ubuntu.com` for arm64 — separate archives, and the amd64 path
404s), the multiarch library directory ICU is detected in, and the Docker apt
repository. A local ARM test VM converges with the same playbook.

## Observability

### VictoriaLogs, natively

The backend was always VictoriaLogs; what changed is how logs reach it.
Fluent Bit now writes to `/insert/jsonline` with its `http` output rather than
through the Loki-compatible endpoint. The Loki path costs a translation on both
sides and **drops every field that is not a stream label**; the native one
stores the whole record and makes each field queryable.

```yaml
name: http
uri: /insert/jsonline?_msg_field=MESSAGE,uri,log,msg&_time_field=date&_stream_fields=instance_name,job,unit
format: json_lines
json_date_format: iso8601
compress: gzip
```

Three details that are easy to get wrong:

- `_msg_field` takes a **comma-separated list** and uses the first field
  present on the record — `MESSAGE` for journald, `uri` for the nginx access
  log. One output definition covers both shapes.
- `_time_field=date` because `json_date_format: iso8601` is what makes Fluent
  Bit write its timestamp under the key `date`.
- `job` had to become a **field on the record**. It was a Loki label, and the
  `http` output has no equivalent of `labels` — so a `modify` filter adds it
  per tag before the record leaves.

`_stream_fields` is the equivalent of Loki's labels and wants the same
restraint: `instance_name,job,unit` for logs, `instance_name,job,app` for nginx.
Everything else stays a queryable field, which is the whole gain.

### The agent's unit

Fluent Bit is installed from the official repository and configured with a
**drop-in**, `/etc/systemd/system/fluent-bit.service.d/10-pscloud.conf`, never
by replacing the packaged unit. A copy in `/etc/systemd/system` would mask
`/lib/systemd/system/fluent-bit.service`: an upgrade that changed `ExecStart`
would be silently ignored, and the mask would survive removing the package. The
role asserts both files appear in `systemctl cat` after every converge.

The drop-in resets `ExecStart=` before setting its own — systemd appends
otherwise and refuses to start — because the packaged unit points at
`fluent-bit.conf` in the classic format and this fleet uses the YAML one.

Configuration is validated with `fluent-bit --dry-run` **before** it is written,
so a broken config never reaches disk, and applied through
`POST /api/v2/reload`, which swaps it without killing the process.

### Swap and pressure, before the OOM kill

The built-in collectors count processes by state, so per-app limits are
invisible to them. `cgroup-textfile-exporter.sh` walks
`/sys/fs/cgroup/apps.slice/dotnet-app@*.service` every 30 seconds.

The two counters that fire *after* the damage:

```
app_oom_kills_total{app}                  killed inside its own MemoryMax
app_mem_events_high_total{app}            went over MemoryHigh
```

The ones that move *before* it, which is the point:

```
app_swap_bytes{app}                       swap in use
app_swap_max_bytes{app}                   its MemorySwapMax
app_swap_pct{app}                         how close to that ceiling
app_swap_fail_total{app}                  swap refused because the ceiling was hit
app_mem_pressure_avg10{app,kind}          share of the last 10s stalled on memory
app_io_pressure_avg10{app,kind}
app_cpu_pressure_avg10{app,kind}
```

`app_swap_fail_total` climbing is the clearest signal there is: the app asked
for swap, `MemorySwapMax` refused it, and the next step is reclaim it cannot
satisfy. `app_mem_pressure_avg10{kind="full"}` above a few percent means every
task in the cgroup is stalled — a process about to be killed, minutes ahead.

Host-wide, `host_swap_used_bytes`, `host_swap_pct` and
`host_pressure_avg10{resource,kind}` answer the same question for the box,
alongside the `SwapTotal`/`SwapFree` and `pswpin`/`pswpout` series the meminfo
and vmstat collectors already produce.

Alert on `app_swap_pct > 50` or `app_mem_pressure_avg10{kind="full"} > 5`, not
on `app_oom_kills_total`. This is also the signal to read between rc and the
canary step of a rollout.

### Adding a collection

A dictionary in the right list in `group_vars/role_app/observability.yml`.
`fluentbit_base_*` (role defaults) and `fluentbit_extra_*` (group_vars) are
concatenated, never replaced. A new parser goes in
`roles/observability_agent/templates/parsers.yaml.j2`.

### The monitoring machine

12 GB, arm64, and **not dedicated to this** — RustDesk and a desktop session
are on the same box. 6 GB is allocated to the stack:

```
victoriametrics   2.0 GB    -memory.allowedBytes=1400MB    1.0 cpu
victorialogs      2.0 GB    -memory.allowedBytes=1400MB    0.8 cpu
grafana           768 MB                                   0.5 cpu
vmalert           256 MB                                   0.2 cpu
alertmanager      192 MB                                   0.1 cpu
                  -------
                  5.2 GB of hard limits, 0.8 GB of headroom inside the 6 GB
```

The rest of the machine: ~2 GB for RustDesk and the desktop, ~1 GB for the OS
and Docker, and ~3 GB left as page cache — which is what VictoriaMetrics and
VictoriaLogs lean on hardest, since both are mmap-based and their read path
*is* the page cache. Giving the containers more would take it from there and
make queries slower, not faster.

**`-memory.allowedBytes` is mandatory on both.** The default,
`-memory.allowedPercent=60`, is computed against the **host's** RAM, not the
container limit: inside a 2 GB container the process would believe it can use
7.2 GB and get killed by the cgroup OOM killer. Each is set to ~70% of its own
limit, leaving the rest for Go's non-heap allocations.

The role asserts the limits add up to no more than `monitoring_mem_budget_mb`,
so an edit that quietly overcommits the machine fails the converge instead of
the OOM killer. Every image publishes a `linux/arm64` manifest, so nothing is
pinned to a platform; the Docker apt repository is the one place the
architecture had to be derived rather than assumed.

Disk ceilings are hard, not targets — leave at least 20% of the filesystem free
on top of them. Merges and compaction need scratch space, and without it
VictoriaMetrics drops into read-only mode, which looks exactly like the fleet
having gone quiet.

## Checking a machine

```sh
systemctl status 'dotnet-app@*'
systemctl cat dotnet-app@pixapi           # template + both drop-ins, with their sources
systemctl cat fluent-bit                  # packaged unit + our drop-in
systemd-cgtop -m /apps.slice              # memory per app against its ceiling
journalctl -u dotnet-app@pixapi -f

curl -s localhost/healthz                             # what the load balancer asks
curl -s localhost:8081/nginx_status                   # connections and request counters
curl -s localhost:2020/api/v1/metrics | jq            # in_records vs out_records vs retries
cat /run/instance.env                                 # OCI identity used as metric labels
grep swap /var/lib/node_exporter/textfile/app_metrics.prom

/opt/dotnet/5.0.15/dotnet --list-runtimes             # one version per root, by design
/opt/dotnet/2.1.30/dotnet --list-runtimes
```

On-disk layout of a deployed application:

```
/srv/apps/<app>/releases/<version>/   the artifact, never written to
/srv/apps/<app>/shared/               state that outlives a release
/srv/apps/<app>/current -> releases/<version>
```

`current` is switched by an atomic symlink replacement, then the unit is
restarted and has to answer on its own port. If it does not, the play puts
`current` back, restarts the previous release, and fails with the last 50
journal lines.

## Fonts

The `fonts` artifact holds the eight faces the report layouts reference by
name. They are unpacked to `/usr/local/share/fonts/msttcore` and then
**verified**, because a bad font file is skipped by `fc-cache` without an error
and `fc-match` always answers with *something*:

1. every expected face comes back from `fc-list` after the unpack;
2. every family in `dotnet_font_families` resolves to a file under our own
   directory, not to the DejaVu fallback;
3. `Arial:bold`, `Arial:italic` and `Tahoma:bold` resolve to their own files
   rather than a synthesised face.

Missing, libgdiplus substitutes a default, the metrics change, and the invoice
comes out with shifted columns — a silent corruption, not an error.

**The Orator family is named `Orator10 BT`, not `Orator`.** A layout asking for
`Orator` matches nothing and silently falls back to Arial. That is why the
family list carries the full name, and why check 2 exists.

## Notes on the two .NET runtimes

Both are out of support and neither has a package for Ubuntu 24.04, so:

- **Separate install roots** (`/opt/dotnet/5.0.15`, `/opt/dotnet/2.1.30`).
  Stacking them in one root overwrites the `dotnet` host binary with the older
  one and makes rollforward behaviour depend on what was installed last. Each
  unit's `ExecStart` names its runtime explicitly.
- **OpenSSL 1.1 is unpacked, not installed.** These runtimes `dlopen`
  `libssl.so.1.1`, which Ubuntu 24.04 does not ship. The `.deb` is extracted
  into `/opt/dotnet/compat/lib` and reached through `LD_LIBRARY_PATH` on the
  app units only — `apt install libssl1.1` would put an unpatched TLS library
  on the search path of every process on the box, sshd included.
- **ICU is handed over explicitly.** They probe `libicuuc.so.<=67`; Ubuntu
  24.04 ships 74, so `CLR_ICU_VERSION_OVERRIDE` is set from the version
  actually detected on the host. The alternative,
  `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`, starts anywhere but degrades
  pt-BR dates, currency and string comparison — it is available per runtime
  (`icu: invariant`) as a fallback, not a default.
- **Workstation GC.** `COMPlus_gcServer=0`. Server GC allocates a heap and a
  thread per core per process; eight processes on two cores would mean sixteen
  heaps competing for 4.4 GB.
