# Ansible

Eight .NET 5 applications behind a local nginx on `VM.Standard.E4.Flex`
(2 vCPU, 6 GB), plus one monitoring server. Immutable in production: a release
is a new machine image, not a machine that was changed.

```
site.yml                     the application servers, end to end
database.yml                 schemas, MySQL accounts and the credentials
monitoring.yml                the monitoring server
deploy.yml                    app + frontend versions on existing machines
image.yml                     the golden image, run by Packer

group_vars/                   SHARED — identical in every environment
inventories/production/       prod: hosts + the vars only prod has
inventories/rc/                rc: its own inventory, never a pool
inventories/local/            Vagrant VMs on the workstation
roles/
```

**Every variable is defined in exactly one place.** Shared config never names a
value an environment overrides, so there is no precedence chain to reason about
when something looks wrong — there is one file to open. What differs between
environments is only:

```
app_env  host_vcpus  host_memory_mb  apps_slice_reserve_mb
oci_auth_type  db_create_schemas
```

prod and rc share a compartment, so each inventory *filters* on the
`pscloud.environment` tag rather than querying separately. Running against the
wrong environment is impossible by construction, not by remembering `--limit`.

---

## Install

Python 3.11+, and that is the only thing you need beforehand. Everything else
lands in this directory and nothing is installed system-wide.

```sh
cd ansible

python3 -m venv .venv
.venv/bin/pip install -r requirements.txt     # ansible + the oci SDK
.venv/bin/ansible-galaxy install -r requirements.yml
```

The second command reads **both** keys in `requirements.yml` — collections into
`collections/`, the one external role into `roles/`. Both are gitignored.

`requirements.txt` pins three things:

| | why |
|---|---|
| `ansible` / `ansible-core` | pinned so a play that works here works on the runner |
| `oci` | the SDK the `oracle.oci` modules and the dynamic inventory need |

The `oci` SDK is on the **controller**, not on the machines. Secrets and
artifacts are read by the controller and handed over; nothing OCI-aware is
installed on a target.

Put the venv on your PATH for the session, or prefix every command with
`.venv/bin/`:

```sh
source .venv/bin/activate
```

## Set up

### 1. Credentials

```sh
cp ../keys/.env.example ../keys/.env
$EDITOR ../keys/.env
source ../keys/.env
```

Three variables decide whether anything works: `OCI_COMPARTMENT_OCID`,
`OCI_VAULT_OCID`, `OCI_VAULT_KEY_OCID`. They come from
`terragrunt output` on `infra/live/<env>/platform`.

The controller authenticates to OCI either with `~/.oci/config` (a workstation)
or with its instance principal (a VM inside the VCN). That is what
`oci_auth_type` selects, and it is the entire local/cloud delta:

```yaml
# inventories/local/group_vars/all.yml
oci_auth_type: api_key          # prod and rc use instance_principal
```

### 2. What must already be in the vault

Read **[REQUIREMENTS.md](REQUIREMENTS.md)** before the first run. Short version:
`pscloud-mysql-admin` comes from Terraform, the names under `secrets:` in the
catalog you create by hand, and the ones under `database.secret` are minted by
`database.yml` on its first run.

```sh
oci secrets secret-bundle get-secret-bundle-by-name \
  --secret-name pscloud-mysql-admin --vault-id "$OCI_VAULT_OCID" \
  --query 'data."version-number"' --raw-output
```

### 3. Inventory

There is **no default inventory**: `-i` is required. prod and rc share a
compartment, so a run without it would go to whichever the default happened to
name.

```sh
ansible-inventory -i inventories/production --graph
ansible-inventory -i inventories/local --graph
```

Pass the *directory*, not the file — that is what loads
`inventories/<env>/group_vars/` alongside the hosts.

Grouping comes from the defined tags Terraform applies, the same tags that
drive the IAM dynamic groups. `inventories/local/hosts.yml` is static; put the
real addresses in it. Hostnames **are** addresses everywhere, matching the OCI
plugin's `hostname_format: private_ip`, so `monitoring_host` resolves the same
way in all three.

### 4. Bastion

The application VMs have no public IP, and Ansible does not proxy through
the Bastion for them — there is no `ProxyCommand` in `group_vars/all.yml`,
on purpose. Instead, **Ansible runs from the monitoring host**: even though
it now sits in the public subnet (section 5) rather than the app one, its
NSG still reaches every app host's private IP directly on the app subnet's
own terms (see `app-in-ssh` in `infra/live/prod/network`), so once you are on
it, the OCI dynamic inventory's `private_ip` hostnames are reachable
directly.

The Bastion is only the door onto that host from outside the VCN. Open a
port forwarding session and hand it to `ssh`:

```sh
bastion_id=$(cd ../infra/live/prod/platform && terragrunt output -raw bastion_id)
monitoring_ip=$(ansible-inventory -i inventories/production --list \
  | jq -r '.role_monitoring.hosts[0]')

session_id=$(oci bastion session create-port-forwarding-session \
  --bastion-id "$bastion_id" \
  --display-name "ssh-$(whoami)-$(date +%s)" \
  --target-private-ip "$monitoring_ip" --target-port 22 \
  --ssh-public-key-file ~/.ssh/id_rsa.pub \
  --wait-for-state SUCCEEDED --wait-for-state FAILED \
  --query 'data.resource.id' --raw-output)

ssh -i ~/.ssh/pscloud-monitoring \
  -o ProxyCommand="ssh -i ~/.ssh/id_rsa -W ${monitoring_ip}:22 ${session_id}@host.bastion.sa-saopaulo-1.oci.oraclecloud.com" \
  ubuntu@"$monitoring_ip"
```

The session (to the Bastion service) authenticates with your own key,
`~/.ssh/id_rsa`; the target itself authenticates with `ansible_ssh_private_key_file`
— `~/.ssh/pscloud-<role>`, the same per-role key Terraform already put in the
image's `authorized_keys`:

```sh
oci secrets secret-bundle get-secret-bundle-by-name \
  --secret-name pscloud-ssh-monitoring --vault-id "$OCI_VAULT_OCID" \
  --query 'data."secret-bundle-content".content' --raw-output \
  | base64 -d > ~/.ssh/pscloud-monitoring
chmod 600 ~/.ssh/pscloud-monitoring
```

Repeat for `pscloud-ssh-app` → `~/.ssh/pscloud-app`: with both keys on the
monitoring host, it can reach the application VMs too, so `site.yml`,
`database.yml` and `deploy.yml` all run from there against
`inventories/production` / `inventories/rc` like any other host — Ansible
itself, installed globally (`roles/ansible_manager`, run as part of
`monitoring.yml`), no venv to activate.

This box also has a public IP now (section 5), so `ssh -i ~/.ssh/pscloud-monitoring
ubuntu@<its public IP>` works directly too, no Bastion session needed — this
section stays useful as the private-network path when that's preferred.

### 5. How pipelines reach this host

Deliberately not through the Bastion, and not a self-hosted runner either —
confirmed: a persistent runner installed on this box is more attack surface
than this needs, and routing every CI run through a fresh Bastion session
added a round-trip for no real gain once the box has its own public IP
anyway. Instead, this box has a public IP (see `infra/live/prod/monitoring`)
and the GitHub Actions workflows (`rc.yml`, `canary.yml`, `promote.yml`,
`image.yml`) SSH straight to it — one composite action,
`.github/actions/run-on-monitoring`, does that; every workflow that needs
`ansible-playbook` or `packer` calls it instead of repeating it. It assumes
this box already has a persistent clone of this repo plus Ansible installed
globally on PATH -- `roles/ansible_manager`, run as part of `monitoring.yml`,
does that bootstrap now instead of it being done by hand.

The SSH key is still the same `pscloud-ssh-monitoring` Vault secret a human
uses (section 4) — fetched with the existing CI OCI API key, the only OCI
credential that lives in GitHub at all. Being public changes what has to
hold the line at the host itself, not just the network: `sshd` here has
`fail2ban` in front of it (`monitoring.yml`), and the `monitoring` NSG's
`0.0.0.0/0:22` rule (`infra/live/prod/network`) is the only public ingress
this box has. Calls that don't need to touch this box at all (`publish.yml`'s
upload, `canary.yml`'s pool/load-balancer control) use the same CI key
directly from a plain `ubuntu-latest` runner over plain HTTPS, no SSH
involved.

### 6. Release groups and canary

Each channel keeps its own version record — `versions_rc.yml`,
`versions_canary.yml`, `versions_stable.yml`, all the same shape
(`release_groups_<channel>`) — see "## Versions" below. `promote.yml` never
reads a version live off a host: it copies one release group from the
source channel's file into the target channel's own file, commits that,
then deploys. Nothing moves into canary or stable except by running
`promote.yml`; nothing moves at all except by running one of `rollout.yml`,
`canary.yml` or `promote.yml`.

`pool_canary`/`pool_stable` are inventory groups, keyed off the
`pscloud_pool` freeform tag `infra/modules/app-tier` sets on each pool's
instance configuration — the same tag-driven pattern the `role_*` groups
already use. rc is never a pool; it's its own inventory (`inventories/rc`).
A host resolves its own channel's file automatically (`app_channel` in
`group_vars/role_app/resolve.yml`), so `deploy.yml` never needs an explicit
version passed in — by the time it runs, the right file already has it.

Rollout `serial` (how fast a version rolls out across the hosts a pool
*already* has) and load-balancer `weight` (what share of real traffic a pool
gets) are different knobs: `promote.yml`'s `weight` input is the former,
`canary.yml action=traffic`'s `weight_percent` is the latter.

The full flow:

```
canary.yml action=up                       scales pool_canary to 1
canary.yml action=traffic weight_percent=10 sends 10% of real traffic there
promote.yml to=canary                       versions_rc.yml -> versions_canary.yml, deploys it
  ...validate...
canary.yml action=snapshot                  optional: image the validated canary
promote.yml to=stable                       versions_canary.yml -> versions_stable.yml, deploys it
canary.yml action=traffic weight_percent=0
canary.yml action=down
```

or, for a low-risk change where the ceremony isn't worth it:

```
promote.yml to=stable from=rc               versions_rc.yml -> versions_stable.yml directly
```

Same action either way, just a different `from` — `promote.yml` doesn't
care whether canary was used first.

## Run

```sh
source ../keys/.env
export ENV=production          # or rc, or local

ansible-playbook -i inventories/$ENV database.yml    # once, and when the
                                                     # catalog's database: changes
ansible-playbook -i inventories/$ENV site.yml
ansible-playbook -i inventories/$ENV monitoring.yml
```

Order matters on a clean environment: `database.yml` mints the credentials that
`site.yml` writes into the env files.

```sh
ansible-playbook -i inventories/production site.yml --check --diff
ansible-playbook -i inventories/production site.yml --tags nginx
ansible-playbook -i inventories/rc deploy.yml
ansible-playbook -i inventories/production deploy.yml -e deploy_serial=25%
```

Tags: `base`, `runtime`, `nginx`, `apps`, `deploy`, `agent`.

Locally, everything is the same except the inventory and the user — the first
run connects as the image's own user because `roles/base` has not created the
accounts yet:

```sh
ansible-playbook -i inventories/local site.yml -u ubuntu
```

---

## Roles

| Role | Owns |
|---|---|
| `base` | accounts and sudo, sysctl, swap, journald, firewall, OCI identity |
| `dotnet_runtime` | the .NET 5 and 2.1 runtimes, OpenSSL 1.1, libgdiplus, the report fonts |
| `dotnet_app` | the systemd slice, unit template, drop-ins, settings, env files |
| `app_deploy` | fetch a version, switch, health-check, roll back -- backend apps and frontends alike |
| `nginx_app` | installs and configures nginx: the package, routing, error pages. Never deploys anything -- see `app_deploy` |
| `db_users` | schemas, one MySQL account per application, and their credentials |
| `observability_agent` | Fluent Bit: unit logs, host and per-app metrics |
| `monitoring_stack` | Docker and the observability backend |

## Versions

There is no manifest service and no `latest` resolution. **What an application
is** lives in the catalog, forever version-free:

```yaml
# group_vars/role_app/applications.yml
applications:
  pixapi:
    dll: VirtualStore.Integrations.Pix.Api.dll
    port: 5008
    path: /pixapi
    tier: critical
    linked_dirs: [Contents]

  virtualstore:
    # ... and an application that talks to a database and reads a secret:
    database:
      secret: db-virtualstore        # the vault name, without the prefix
      schemas:
        VSGlobalContext: virtualstoreglobal
        CepContext: cep
    secrets:
      SmtpClientData__MailPass: smtp-password

static_sites:
  root:            { path: /,               index: /index.html }
  app:             { path: /app,            index: /app/index.html }
  monitorclientes: { path: /monitorclientes, index: /monitorclientes/index.html }
```

**What version is running where** lives in three committed files, one per
channel — `versions_rc.yml`, `versions_canary.yml`, `versions_stable.yml` —
same shape, each keyed `release_groups_<channel>`. rc's is the complete
catalog; canary's and stable's start empty and only ever gain an entry
through a `promote.yml` run (see "### 6. Release groups and canary" above).
Organized by **release group**: a group names its member apps *and* each
one's own version, so a frontend and the backend(s) it always ships with can
be promoted together as one release even though each still publishes on its
own schedule:

```yaml
# group_vars/role_app/versions_rc.yml
release_groups_rc:
  monitorclientes:              # Flutter frontend + both its backends
    monitorclientes: "2026.09.12"
    monitorclientesapi: "2026.09.10"
    geradorrelatoriosapi: "2026.09.11"
  pixapi:                       # most groups have one member
    pixapi: "2026.09.12"

# group_vars/role_app/versions_canary.yml -- empty until promoted
release_groups_canary:
  pixapi:
    pixapi: "2026.09.10"        # an earlier rc version -- canary hasn't
                                 # caught up yet, and that's fine
```

**Every secret an application uses is named in its own entry.** Nothing is
derived from the application's name, so `grep db-virtualstore` finds every use
of it, and the `<prefix>-` half is added in one place — the catalog is the same
in every environment.

Releasing to rc is: CI uploads a tarball, `bump-rc.yml` opens a PR bumping one
line, it merges, `rollout.yml` runs on its own. Rolling rc back is checking
out a previous commit of `versions_rc.yml` and running `rollout.yml` again.
Canary and stable move only through `promote.yml`, which commits the copy
itself — `git log` on either file is exactly as good a record for them as it
already is for rc. Adding an application is one entry plus one line in
whichever release group it belongs to — it produces the systemd unit and its
limits, the nginx upstream and `location`, the database account and its
credential, the env file, the appsettings overlay, the `app` label on logs
and metrics, and the deploy target. No role, task or template changes.

## The bucket

```
artifacts/<name>/<name>-<version>.tar.gz
```

Eleven artifacts: the eight publish trees, plus the three frontends,
separately now — `root` (the Ionic storefront at `/`), `app` and
`monitorclientes` (the two Flutter builds, at `/app` and `/monitorclientes`).

Tarballs are packed from **inside** each directory, so the entry assembly (or,
for a frontend, the site's own files) lands at the root of the release:

```sh
tar -C out -czf pixapi.tar.gz .
```

State directories (`Contents`, `Relatorios`, `ArquivosFiscais`, `Fonts`, `logs`)
are excluded: they are `linked_dirs` and live in `shared/`, so a deploy must not
overwrite them.

## Secrets

Always OCI Vault. No `vault.yml`, no ansible-vault, nothing in git. The
controller reads them with `oracle.oci`'s own modules and writes the value into
`/etc/dotnet-apps/<app>.env`, `0640 root:dotnetapp` — the only place on a
machine a password appears, and `systemctl show` does not print it.

Each `pscloud-db-<app>` is a JSON document carrying the whole DSN, so an
application needs nothing else to build a connection string:

```json
{ "host": "...", "port": 3306, "database": "virtualstoreglobal",
  "username": "virtualstore_app", "password": "...",
  "grants": ["SELECT","INSERT","UPDATE","DELETE"], "host_acl": "10.20.%" }
```

`database.yml` owns these end to end: it mints the password, stores it, and
creates the MySQL account in the same run. Terraform cannot — the DB System is
private and unreachable from where it runs, so it would have to write a secret
and hope an account followed.

Reading is always `stage: CURRENT`, which is what makes rotation work: a new
version in the vault is picked up by the next converge.

```sh
ansible-playbook database.yml -e db_rotate=true   # new version, MySQL follows
ansible-playbook site.yml --tags apps             # straight after
```

Between the two, the applications still hold the previous password — the vault
keeps both versions — so run them back to back.

See **[REQUIREMENTS.md](REQUIREMENTS.md)** for what must exist beforehand and
how to migrate the credentials Terraform used to own.

## Accounts

Created by `roles/base`. Nothing logs in as root, no application runs as a human.

| | shell | sudo | for |
|---|---|---|---|
| `dotnetapp` | `nologin` | none | running the applications; owns `/srv/apps` |
| `deploy` | bash, key-only | full, `NOPASSWD` | automation; Ansible connects as this |
| `ops` | bash, key-only | a short allowlist | humans on a misbehaving machine |

`deploy` has full sudo because Ansible's modules run as root and an allowlist
covering them is an allowlist for root. What the separation buys is a keyed,
non-interactive, password-locked identity with its own audit trail.

`ops` is where the restriction is real: `systemd-journal` and `adm` membership
cover most of it, and its sudo list is `systemctl status|cat|show`,
`journalctl`, `systemd-cgtop`, plus exactly one write —
`systemctl restart dotnet-app@*`. It cannot touch nginx, sshd or the agent.

Public keys go in `base_users.<name>.ssh_keys`; `exclusive: true` means the list
in the repository *is* the list on the machine.

## Database accounts

One account per application, `<app>_app`, granted only on the schemas its
`connections` reference. It replaces two shared logins: `glb_user` was used by
four applications and `cep_user` by three, so a leaked connection string from
the reports API opened the sales database for writing.

```
virtualstore_app          cep.*:SELECT / virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE
monitorclientes_app       virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE
geradorrelatorios_app     virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE
cadastrosapi_app          cep.*:SELECT
entradaapi_app            cep.*:SELECT / virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE
```

`dashsapi`, `relatoriosapi` and `pixapi` have no `connections`, so they get no
account. `cep` is read-only for everyone. `DROP`, `ALTER` and `CREATE` are
absent: a schema change is a migration, run deliberately.

The schemas do not have to exist — MySQL accepts a grant on a database that is
not there yet.

`database.yml` runs from an application VM (`run_once`), because the NSG only
lets the app tier reach 3306. Accounts use `caching_sha2_password`; the role
sets `plugin` + `plugin_auth_string` + `salt` rather than `password:`, which the
module would silently downgrade to a native-password account.

## The host

Terraform passes no `user_data`: a cloud-init copy of this would be a second
definition to keep in step, and it would only run on first boot.

Only settings that are safe regardless of traffic shape — each is either a limit
the workload provably reaches, or a default that is wrong for a reverse proxy in
front of loopback services:

- `vm.overcommit_memory=1` — a .NET process reserves far more address space than
  it touches, and strict accounting refuses the reservation.
- `vm.max_map_count=262144` — eight runtimes mapping hundreds of assemblies
  reach the 65530 default long before a memory limit.
- `tcp_slow_start_after_idle=0` — the upstreams are keepalive and idle between
  bursts; without this the first request after a gap pays for it.
- THP on `madvise`, no guest I/O scheduler on a paravirtualised disk.
- Swap, 2 GB, swappiness 10 — so a GC spike pages out instead of tripping the
  OOM killer.
- `base_open_ports` inserts ACCEPT ahead of the REJECT the OCI Ubuntu image
  ships. This is the one thing cloud-init did that had to move somewhere.

The file is written whole, not key by key: `ansible.posix.sysctl` only adds and
updates, so a setting deleted from `base_sysctl` would stay on the machine
forever and the dictionary would stop describing it.

The application VMs are x86_64 and the monitoring machine is arm64, so the
runtime tarballs, the OpenSSL `.deb` (amd64 on `security.ubuntu.com`, arm64 on
`ports.ubuntu.com` — separate archives) and the Docker apt repository all derive
from `ansible_facts['architecture']`.

## Runtime

Runtimes only, no SDK. `dotnet_versions` installs `Microsoft.AspNetCore.App`
2.1.30 and 5.0.15 side by side under `/opt/dotnet`; an application resolves the
framework it was built against by itself, so there is no per-application
selection. The list is unpacked oldest first on purpose: each bundle carries its
own muxer and `host/fxr`, and `dotnet` loads the highest `hostfxr` it finds —
the only one able to start both.

An aarch64 host gets 5.0 alone. Microsoft never published
`aspnetcore-runtime-2.1.30-linux-arm64` — 2.1 shipped `linux-x64` and
`linux-arm` only — so `dotnet_versions` drops 2.1.30 off arm64 rather than 404
in the middle of a play.

- **OpenSSL 1.1 is unpacked, not installed.** .NET 5 `dlopen`s
  `libssl.so.1.1`, which Ubuntu 24.04 does not ship. The `.deb` is extracted to
  `/opt/dotnet/compat/lib` and reached through `LD_LIBRARY_PATH` on the app
  units only — `apt install libssl1.1` would put an unpatched TLS library on the
  search path of every process, sshd included.
- **ICU is handed over explicitly.** .NET 5 probes `libicuuc.so` up to 67 and
  Ubuntu 24.04 ships 74, so `CLR_ICU_VERSION_OVERRIDE` is set from the detected
  version. That knob arrived in .NET Core 3.0, so a 2.1 application ignores it
  and finds no ICU it recognises: globalization for anything actually deployed
  on 2.1 has to be settled separately. Nothing in `applications.yml` targets 2.1
  today.
- **Workstation GC.** `COMPlus_gcServer=0`: server GC allocates a heap and a
  thread per core per process, and eight processes on two cores would mean
  sixteen heaps competing for 4.4 GB. The `COMPlus_` prefix is deliberate —
  `DOTNET_` only became valid in .NET 6 and would be silently ignored here.

**Fonts** ship with the role. `fc-cache` runs when they change and `fc-match`
has to resolve each family to a file under `/usr/local/share/fonts/msttcore` —
it always answers with *something*, so the answer is what matters. Missing,
libgdiplus substitutes a default and invoices come out with shifted columns.
**The Orator family is named `Orator10 BT`, not `Orator`**; a layout asking for
`Orator` silently falls back to Arial.

## Observability

Logs go to VictoriaLogs through Fluent Bit's `http` output on
`/insert/jsonline` — the native endpoint, not the Loki-compatible one, which
drops every field that is not a stream label.

Fluent Bit is configured with a **drop-in**, never a copy of the unit in
`/etc/systemd/system` — that would mask the packaged one and an upgrade
changing `ExecStart` would be silently ignored. Configuration is validated with
`--dry-run` before it is written and applied with `POST /api/v2/reload`.

### Swap and pressure, before the OOM kill

`cgroup-textfile-exporter.sh` walks the app cgroups every 30 seconds. The two
counters that fire *after* the damage:

```
app_oom_kills_total{app}          app_mem_events_high_total{app}
```

The ones that move *before* it:

```
app_swap_bytes{app}   app_swap_pct{app}   app_swap_fail_total{app}
app_mem_pressure_avg10{app,kind}   app_io_pressure_avg10   app_cpu_pressure_avg10
```

`app_swap_fail_total` climbing is the clearest signal there is: the app asked
for swap, `MemorySwapMax` refused, and the next step is reclaim it cannot
satisfy. `app_mem_pressure_avg10{kind="full"}` above a few percent means every
task in the cgroup is stalled — a process about to be killed, minutes ahead.

Alert on `app_swap_pct > 50` or `app_mem_pressure_avg10{kind="full"} > 5`, not
on `app_oom_kills_total`.

### The monitoring machine

8 GB, arm64, dedicated (`VM.Standard.A1.Flex`, freetier, `infra/live/prod/monitoring`).
Unlike everything else, it has a public IP — Grafana is reached directly on
it (`monitoring-in-grafana` in `infra/live/prod/network`), and so is SSH,
which is how CI pipelines reach it (section 5) with no bastion and no
self-hosted runner. It also doubles as the Ansible control node for prod and
rc — see section 4. 6 GB is allocated:

```
victoriametrics  2.0 GB   -memory.allowedBytes=1400MB
victorialogs     2.0 GB   -memory.allowedBytes=1400MB
grafana          768 MB     vmalert 256 MB     alertmanager 192 MB
                 5.2 GB of limits, 0.8 GB headroom
```

`-memory.allowedBytes` is mandatory on both: the default is computed against the
**host's** RAM, so inside a 2 GB container the process would believe it can use
7.2 GB and get OOM-killed. The role asserts the limits fit
`monitoring_mem_budget_mb`. The rest of the box stays page cache, which is what
both lean on hardest — they are mmap-based.

## Where a change goes

| Change | File |
|---|---|
| a new application, or what it's not versioned by | `group_vars/role_app/applications.yml` |
| an application's version | `group_vars/role_app/versions_<channel>.yml` |
| what an application may spend | `app_tiers` in `platform.yml` |
| an nginx timeout, the runtime version | `platform.yml` |
| an appsettings value, a database, a secret name | `config.yml` |
| a Fluent Bit collection | `observability.yml` |
| the VM shape | `host_vcpus` / `host_memory_mb` in `all.yml` |
| accounts, sudo, kernel tuning, swap | `roles/base/defaults/main.yml` |
| the monitoring budget | `group_vars/role_monitoring.yml` |

## Checking a machine

```sh
systemctl status 'dotnet-app@*'
systemctl cat dotnet-app@pixapi      # template + both drop-ins, with sources
systemd-cgtop -m /apps.slice
journalctl -u dotnet-app@pixapi -f

curl -s localhost/healthz
curl -s localhost:8081/nginx_status
grep swap /var/lib/node_exporter/textfile/app_metrics.prom
```

```
/srv/apps/<app>/releases/<version>/   the artifact, never written to
/srv/apps/<app>/shared/               state that outlives a release
/srv/apps/<app>/current -> releases/<version>
```
