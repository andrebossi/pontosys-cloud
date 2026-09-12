# Ansible

Eight .NET 5 applications behind a local nginx on `VM.Standard.E4.Flex`
(2 vCPU, 6 GB), plus one monitoring server. Immutable in production: a release
is a new machine image, not a machine that was changed.

```
site.yml         the application servers, end to end
monitoring.yml   the monitoring server
deploy.yml       install the application versions on existing machines
image.yml        the golden image, run by Packer
```

| Role | Owns |
|---|---|
| `base` | accounts and sudo, sysctl, swap, journald, firewall, OCI identity |
| `pscloud` | the `pscloud` CLI: artifacts out of the bucket, secrets out of the vault |
| `dotnet_runtime` | the .NET 5 and 2.1 runtimes, OpenSSL 1.1, libgdiplus, the report fonts |
| `dotnet_app` | the systemd slice, unit template, drop-ins, settings, env templates |
| `app_deploy` | fetch a version, switch, health-check, roll back |
| `nginx_app` | nginx, routing, error pages, the web root |
| `db_users` | one MySQL account per application |
| `observability_agent` | Fluent Bit: unit logs, host and per-app metrics |
| `monitoring_stack` | Docker and the observability backend |

## Versions

There is no manifest service and no `latest` resolution. **The version is in the
catalog**, and git is the record of what every environment ran:

```yaml
# group_vars/role_app/applications.yml
applications:
  pixapi:
    version: "2026.09.12"
    dll: VirtualStore.Integrations.Pix.Api.dll
    port: 5008
    path: /pixapi
    tier: critical
    linked_dirs: [Contents]
    connections: {}

webroot_version: "2026.09.12"
```

Releasing is: CI uploads a tarball, someone bumps the number, the rollout runs.
Rolling back is checking out the previous commit and running it again. Adding an
application is one entry — it produces the systemd unit and its limits, the
nginx upstream and `location`, the database account and its generated password,
the env file, the appsettings overlay, the `app` label on logs and metrics, and
the deploy target. No role, task or template changes.

## The one difference between local and cloud

Everything reads the same bucket and the same vault. Only the identity changes,
and `pscloud` picks it automatically:

```
~/.oci/config exists  ->  use it          (a workstation, or a local VM)
otherwise             ->  instance principal   (any machine in OCI)
```

`group_vars/env_local.yml` sets `oci_config_dir: ~/.oci`, which copies the key
to `/root/.oci` on the test VMs. That is the entire local/cloud delta — there is
no local artifact store, no local secret file, and no second code path.

## The bucket

```
artifacts/<name>/<name>-<version>.tar.gz
```

Nine artifacts: the eight publish trees, and `webroot` — the Ionic storefront at
`/` plus the two Flutter builds at `/app` and `/monitorclientes`, in one tarball
unpacked over the document root.

`scripts/package.sh` builds all of it from the old machine's document root:

```sh
scripts/package.sh files/nginx-config 2026.09.12
for f in out/*/*.tar.gz; do
  n=$(basename "$(dirname "$f")"); v=$(basename "$f" .tar.gz); v=${v#"$n"-}
  pscloud push "$n" "$v" "$f"
done
```

Tarballs are packed from **inside** each directory, so the entry assembly lands
at the root of the release. Three things are excluded: **state directories**
(`Contents`, `Relatorios`, `ArquivosFiscais`, `Fonts`, `logs`) because they are
`linked_dirs` and live in `shared/`; **build leftovers** (`publish/`, `ref/`);
and nothing else. The script prints the `rsync` lines that seed the state
directories once per machine.

## Secrets

Always OCI Vault. No `vault.yml`, no ansible-vault, nothing in git, and no value
ever passes through an Ansible fact.

```sh
pscloud secret pscloud-prod-db-app_pixapi
```

Reads the secret, or generates a 32-character password and stores it on first
use. `db_users` calls it to create the MySQL account; `dotnet_app` writes
`/etc/dotnet-apps/<app>.env.template` with `@@name@@` placeholders and
`pscloud env` fills them in.

```
ConnectionStrings__VSGlobalContext=…;user=app_virtualstore;password=@@pscloud-prod-db-app_virtualstore@@;…
```

The same command is a systemd unit, `pscloud-env.service`, ordered before the
applications. That is what lets the golden image carry **no credential** and
still produce a machine that boots serving: a pool member resolves its own
secrets on first boot with its own instance principal.

Credentials shared with systems outside the fleet are created once by hand and
only read — `pscloud-<env>-db-admin`, `pscloud-<env>-smtp-password`,
`pscloud-<env>-jwt-monitorclientes`:

```sh
oci vault secret create-base64 --compartment-id "$OCI_COMPARTMENT_OCID" \
    --vault-id "$OCI_VAULT_OCID" --key-id "$OCI_VAULT_KEY_OCID" \
    --secret-name pscloud-prod-smtp-password \
    --secret-content-content "$(printf %s 'the password' | base64)"
```

> The `appsettings.json` inside each artifact still carries the **old** shared
> credentials. The env file overrides all of them, so nothing uses those values,
> but they are readable on disk. **Rotate them.**

## The pipelines

Three workflows in `.github/workflows/`, all on a **self-hosted runner on the
monitoring server** — it is inside the VCN and its instance principal is the
identity Packer and Ansible use, so no OCI key is stored in GitHub.

### `publish.yml` — called by an application repository

```yaml
jobs:
  publish:
    uses: pontosys/pscloud/.github/workflows/publish.yml@main
    with: { name: pixapi, version: 2026.09.12, path: ./out }
```

Packs the publish directory and uploads it. Nothing is deployed: the artifact
just exists in the bucket now.

### `image.yml` — the immutable machine

Runs on a push to `ansible/**` or `packer/**`, or by hand. Packer boots a stock
Ubuntu, hands it to `image.yml`, and captures the result. It prints the image
OCID and prunes all but the five newest.

The image comes out complete, because a pool member has to boot serving and
nothing runs `site.yml` against a machine that appeared by itself: the runtime
and fonts, nginx and the web root, the units and drop-ins, the agent, and **the
applications at the versions in `applications.yml`**.

Rolling it out is setting `app_image_id` in `infra/live/<env>/app-tier` and
applying — a reviewed Terraform change, which is why nothing here calls the
compute API.

### `rollout.yml` — the canary, on existing machines

Three separate runs, each triggered by a person:

| stage | limit | serial |
|---|---|---|
| `rc` | `env_rc` — a few machines that are in the production load balancer | 1 |
| `canary` | `env_prod` | 1 |
| `prod` | `env_prod` | 25% |

`rc` is not a copy of production. It is a small number of **production
machines**, tagged `pscloud.environment = rc`, taking real traffic. A release
goes there first and is watched. Between stages, read the swap and pressure
series below — that is what says whether it held.

Every deploy health-checks the app on its own port after the symlink switch and
rolls that machine back, with the last 50 journal lines, if it does not answer.

### Two paths, on purpose

```
new application version   ->  publish.yml  ->  bump version  ->  rollout.yml
                                                             \-> image.yml (next machine)

new base configuration    ->  image.yml    ->  app_image_id in Terraform
```

Existing machines are updated in place by `rollout.yml`; machines created from
then on come from the image. Both install the same versions, from the same
tarballs, through the same role — the only untested difference is a fresh unpack
rather than one over an existing tree.

## Testing locally

Three Ubuntu 24.04 VMs. The same code, the same bucket, the same vault.

```sh
for n in 10 11 12; do
  multipass launch 24.04 --name pscloud-$n --cpus 2 --memory 4G --disk 20G
done

docker run -d --name pscloud-mysql -p 3306:3306 -e MYSQL_ROOT_PASSWORD=localdev mysql:8.4

export OCI_COMPARTMENT_OCID=… OCI_VAULT_OCID=… OCI_VAULT_KEY_OCID=…
export PSCLOUD_DB_HOST=192.168.122.1     # reachable from the VMs, not 127.0.0.1

ansible-galaxy install -r requirements.yml
ansible-playbook -i inventory/local.yml monitoring.yml -u ubuntu
ansible-playbook -i inventory/local.yml site.yml       -u ubuntu
```

Copy `inventory/local.yml` and put the real addresses in it; hostnames are
addresses, matching the OCI plugin's `hostname_format: private_ip`, so
`monitoring_host` resolves the same way in both places. The first run connects
as the image's own user because `roles/base` has not created the accounts yet;
after that, `-u deploy`.

Create `pscloud-local-db-admin` in the vault with the container's root password
before the first run. Everything else generates itself.

What local does not cover: the instance metadata service (labels come back
`unknown`), the load balancer and therefore the rc-in-prod idea, and the golden
image.

## Deploying to the cloud

From the monitoring server — the only host with a public IP, the jump host, and
the Ansible executor:

```sh
export OCI_COMPARTMENT_OCID=… OCI_VAULT_OCID=… OCI_VAULT_KEY_OCID=… PSCLOUD_DB_HOST=…
ansible-playbook monitoring.yml
ansible-playbook site.yml
```

`ansible.cfg` points at `inventory/oci.yml`, so no `-i`. Grouping comes from the
defined tags Terraform applies — the same tags that drive the IAM dynamic
groups.

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

One account per application, `app_<name>`, granted only on the schemas its
`connections` reference. It replaces two shared logins: `glb_user` was used by
four applications and `cep_user` by three, so a leaked connection string from
the reports API opened the sales database for writing.

```
app_virtualstore          cep.*:SELECT / virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE,EXECUTE
app_monitorclientesapi    virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE,EXECUTE
app_geradorrelatoriosapi  virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE,EXECUTE
app_cadastrosapi          cep.*:SELECT
app_entradaapi            cep.*:SELECT / virtualstoreglobal.*:SELECT,INSERT,UPDATE,DELETE,EXECUTE
```

`dashsapi`, `relatoriosapi` and `pixapi` have no `connections`, so they get no
account. `cep` is read-only for everyone. `DROP`, `ALTER` and `CREATE` are
absent: a schema change is a migration, run deliberately.

The schemas do not have to exist — MySQL accepts a grant on a database that is
not there yet.

```sh
ansible-playbook site.yml --tags db
```

Runs from an application VM (`run_once`), because the NSG only lets the app tier
reach 3306. Accounts use `caching_sha2_password`; the role sets `plugin` +
`plugin_auth_string` + `salt` rather than `password:`, which the module would
silently downgrade to a native-password account.

## The host

Terraform passes no `user_data`: a cloud-init copy of this would be a second
definition to keep in step, and it would only run on first boot.

- `vm.overcommit_memory=1` — a .NET process reserves far more address space than
  it touches, and strict accounting refuses the reservation.
- `vm.max_map_count=262144` — eight runtimes mapping hundreds of assemblies
  reach the 65530 default long before a memory limit.
- BBR + fq, `tcp_slow_start_after_idle=0` — the upstreams are keepalive and idle
  between bursts; without this the first request after a gap pays for it.
- THP on `madvise`, no guest I/O scheduler on a paravirtualised disk.
- Swap, 2 GB, swappiness 10 — so a GC spike pages out instead of tripping the
  OOM killer.
- `base_open_ports` inserts ACCEPT ahead of the REJECT the OCI Ubuntu image
  ships. This is the one thing cloud-init did that had to move somewhere.

The application VMs are x86_64 and the monitoring machine is arm64, so the
runtime tarballs, the OpenSSL `.deb` (amd64 on `security.ubuntu.com`, arm64 on
`ports.ubuntu.com` — separate archives) and the Docker apt repository all derive
from `ansible_architecture`.

## Runtime

Runtimes only, no SDK. `dotnet_versions` installs `Microsoft.AspNetCore.App`
2.1.30 and 5.0.15 side by side under `/opt/dotnet`; an application resolves the
framework it was built against by itself, so there is no per-application
selection. The list is unpacked oldest first on purpose: each bundle carries its
own muxer and `host/fxr`, and `dotnet` loads the highest `hostfxr` it finds —
the only one able to start both.

An aarch64 host gets 5.0 alone. Microsoft never published
`aspnetcore-runtime-2.1.30-linux-arm64` — 2.1 shipped `linux-x64` and
`linux-arm` only — so `dotnet_versions` drops 2.1.30 off x64 rather than 404 in
the middle of a play. The application VMs are x86_64 and get both.

- **OpenSSL 1.1 is unpacked, not installed.** .NET 5 `dlopen`s
  `libssl.so.1.1`, which Ubuntu 24.04 does not ship. The `.deb` is extracted to
  `/opt/dotnet/compat/lib` and reached through `LD_LIBRARY_PATH` on the app
  units only — `apt install libssl1.1` would put an unpatched TLS library on the
  search path of every process, sshd included.
- **ICU is handed over explicitly.** .NET 5 probes `libicuuc.so` up to 67 and
  Ubuntu 24.04 ships 74, so `CLR_ICU_VERSION_OVERRIDE` is set from the detected
  version. That knob arrived in .NET Core 3.0, so a 2.1 application ignores it
  and finds no ICU it recognises: globalization for anything actually deployed
  on 2.1 has to be settled separately — invariant mode, or an old `libicu`
  staged the way OpenSSL is. Nothing in `applications.yml` targets 2.1 today.
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
on `app_oom_kills_total`. This is what to read between the `rc` and `canary`
stages of a rollout.

### The monitoring machine

12 GB, arm64, shared with RustDesk. 6 GB is allocated:

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
| an application version, or a new application | `group_vars/role_app/applications.yml` |
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
pscloud secret pscloud-prod-db-app_pixapi
```

```
/srv/apps/<app>/releases/<version>/   the artifact, never written to
/srv/apps/<app>/shared/               state that outlives a release
/srv/apps/<app>/current -> releases/<version>
```
