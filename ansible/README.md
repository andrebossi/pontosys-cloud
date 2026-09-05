# Ansible

Configuration for the OCI fleet. The application VMs are
`VM.Standard.E4.Flex`, **1 OCPU (2 vCPU) and 6 GB**, each running nine .NET
processes behind a local nginx — every ceiling in here follows from those two
numbers.

```
inventory/oci.yml          dynamic inventory, grouped by the pscloud.* defined tags
group_vars/all.yml         every VM
group_vars/role_app/       the application VMs — catalog, sizing, nginx, deploy
group_vars/role_monitoring.yml
host_vars/<private ip>.yml one machine
roles/                     see below
files/nginx/               the previous machine's document root and units
site.yml                   converge everything
deploy.yml                 install an application version on machines
release.yml                version manifests: show, promote, rollback
image.yml                  golden image, run by Packer
```

| Role | What it owns |
|---|---|
| `base` | timezone, sysctl, swap, journald, OCI identity |
| `dotnet_runtime` | the two .NET runtimes, OpenSSL compat, libgdiplus, fonts |
| `dotnet_app` | the systemd slice, unit template, drop-ins, config and secrets |
| `app_deploy` | fetch an artifact, switch, health-check, roll back |
| `app_release` | version manifests and the artifact store, on OCI Object Storage |
| `app_image` | golden image lifecycle: release to a pool, prune |
| `app_canary` | traffic shifting between pools, and the metric gate |
| `nginx_app` | nginx from the official role, routing, error pages, static content |
| `observability_agent` | Fluent Bit: unit logs, host metrics, nginx metrics |
| `monitoring_stack` | the observability backend on the monitoring VM |

## Running it

```sh
ansible-galaxy install -r requirements.yml

export OCI_COMPARTMENT_OCID=ocid1.compartment.oc1..xxx
export GITHUB_TOKEN=github_pat_...            # only for deploy.yml

ansible-inventory --graph                     # role_app, role_monitoring, env_prod
ansible-playbook site.yml --check --diff      # dry run
ansible-playbook site.yml
```

`ansible.cfg` already points at the dynamic inventory, so no `-i`. The
monitoring VM is the only host with a public IP and is the jump host into the
private subnets.

## Where a change goes

Almost everything is a dictionary edit. The rule: if it is true for the whole
role it belongs in `group_vars/role_*`, if it is true for one machine it
belongs in `host_vars/`. There is no `when: role == ...` anywhere in the tasks.

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

That single entry produces the systemd unit and its drop-ins, the nginx
upstream and `location`, the env file, the appsettings overlay, the `app`
label on every log line and request metric, and the deploy target. No role,
task or template changes.

Keys: `runtime` picks a .NET version (default 5.0), `drawing: true` pulls in
libgdiplus and the fonts, `linked_dirs` lists directories holding state that
must survive a release, `artifact:` overrides the GitHub repo or asset name.

### Changing what a machine may spend

`group_vars/role_app/sizing.yml`. `app_tiers` sets the ceilings per class;
`apps_slice_*` sets the ceiling for all of them together. An individual app
can override any tier value inline in its catalog entry.

Re-shaping the VM is `host_vcpus` and `host_memory_mb` in `group_vars/all.yml`
— the slice ceilings, the nginx worker count and the GC limits are derived
from them.

### Adding a Fluent Bit collection

A dictionary in the right list in `group_vars/role_app/observability.yml`:

```yaml
fluentbit_extra_inputs:
  - name: tail
    tag: custom.audit
    path: /var/log/audit/audit.log
    parser: syslog-rfc5424
    db: /var/lib/fluent-bit/audit.db

fluentbit_extra_outputs:
  - name: loki
    match: custom.audit
    host: "{{ monitoring_endpoints.logs.host }}"
    port: "{{ monitoring_endpoints.logs.port }}"
    uri: "{{ monitoring_endpoints.logs.uri }}"
    labels: job=audit,instance=${INSTANCE_NAME}
```

`fluentbit_base_*` (role defaults) and `fluentbit_extra_*` (group_vars) are
concatenated, never replaced. A new parser goes in
`roles/observability_agent/templates/parsers.yaml.j2`.

The rendered configuration is checked with `fluent-bit --dry-run` **before**
it is written, so a broken config never reaches disk and the agent keeps
running with the last good one.

### Moving the monitoring backend

`monitoring_endpoints` in `group_vars/all.yml`. One edit, no template changes.

## Secrets

```sh
cp group_vars/role_app/vault.yml.example group_vars/role_app/vault.yml
# fill it in
ansible-vault encrypt group_vars/role_app/vault.yml
ansible-playbook site.yml --ask-vault-pass
```

`vault.yml` is gitignored. Secrets are rendered into `/etc/dotnet-apps/<app>.env`
(0640 root:dotnetapp) as environment variables, which outrank every JSON file
in .NET configuration. They are not in the artifact, not in the image, and not
in `systemctl show`.

> The `appsettings.json` files under `files/nginx/nginx-config/` are copies of
> the old machine and contain live database, SMTP and JWT credentials, in git
> history. **Those need rotating.**

## The release model

Two speeds, because the layers change at different rates:

| | changes | delivered by | takes |
|---|---|---|---|
| **base** — OS, runtimes, nginx, agent, unit files | monthly | a baked image | ~10 min |
| **apps** — the `dotnet publish` trees | hourly | `app_deploy` | ~30 s |

**RC is mutable, prod is immutable**, and that follows from the infrastructure
rather than from taste: RC has fixed instances with stable addresses, so
nothing is replaced underneath a deploy; prod is an autoscaling pool where a
machine can appear at any moment and must boot complete.

### The manifest is what keeps them honest

Everything hangs off one object in the bucket:

```json
{ "release": "2026.09.12-1", "env": "rc", "base_commit": "d1ce447",
  "apps": { "virtualstore": "2.9.1", "pixapi": "1.10.0" } }
```

RC **writes** it after a successful deploy. Promotion **copies** it verbatim.
Packer **bakes** from it. Rollback is an older one. Without it, "the image
built at release completion" and "what RC actually validated" would only be
related by hope.

`group_vars/env_rc.yml` sets `app_version_source: latest` — RC chases the tip
and records what it got. `group_vars/env_prod.yml` sets `manifest` — prod
installs exactly what promotion pinned, and `latest` is not an option there.

### The store

OCI Object Storage, not GitHub, for one reason above the others: a machine
downloads through a **pre-authenticated URL minted by the orchestrator**, so an
autoscaled VM needs no token of its own and the bytes go over the service
gateway instead of the NAT gateway. GitHub stays the source of record; CI
mirrors a published release in.

```
artifacts/<app>/<app>-<version>.tar.gz
manifests/<env>/current.json
manifests/<env>/<release>.json
```

### The loop

> The first play of `deploy.yml` installs the `release` driver on the
> monitoring VM. A `--limit` narrows that play too, so run
> `ansible-playbook release.yml` once on a fresh monitoring VM — after that,
> `-l env_rc` works on its own.

```sh
# CI, on release published
dotnet publish -c Release -o out && tar -C out -czf pixapi.tar.gz .
release push pixapi 1.10.0 ./pixapi.tar.gz

# RC: in place, no image, seconds
ansible-playbook deploy.yml -l env_rc

# what RC validated becomes prod's target -- versions copied verbatim
ansible-playbook release.yml -e release_action=promote \
                             -e release_from_env=rc -e release_to_env=prod

# bake it. From the monitoring VM: its instance principal is what mints the
# artifact URLs, and it is already the Ansible executor.
cd packer && packer build -var compartment_ocid=$OCI_COMPARTMENT_OCID app.pkr.hcl

# roll it out
ansible-playbook deploy.yml -e image_action=release          # canary pool -> new image
ansible-playbook deploy.yml -e canary_action=up
ansible-playbook deploy.yml -e canary_action=shift -e canary_percent=25
ansible-playbook deploy.yml -e canary_action=gate            # fails the step if worse
ansible-playbook deploy.yml -e canary_action=promote
ansible-playbook deploy.yml -e image_action=prune            # keeps 5
```

**Two triggers for an image build, not one.** A release published, *and* a push
touching `roles/{base,dotnet_runtime,nginx_app,observability_agent}/**` —
otherwise a runtime security patch waits for an unrelated app release.

`image prune` keeps the 5 newest **plus every image an instance pool
references**, with a minimum age. The pool protection is the part that matters:
the image in production is routinely older than several builds that came after
it.

### The gate

`canary gate` reads VictoriaMetrics and exits non-zero when the canary looks
worse than stable. It compares on the `pool` label, which reaches the metrics
from `/run/instance.env` — `image release` writes it into the instance
configuration's metadata.

```
window          : 10m
canary requests : 5000
5xx  canary     : 0.50%      p95 canary : 0.100s
5xx  stable     : 0.50%      p95 stable : 0.090s
gate passed
```

Three ways it fails, all deliberate: **too little traffic** is not a pass (a
canary that served nine requests proves nothing); an **absolute** 5xx ceiling;
and a **delta against stable**, because a release is only bad if it is worse
than what it replaces — a 4% baseline on both sides is a pre-existing problem,
not a regression. Thresholds are `canary_gate_*` in the role defaults.

### Rollback

```sh
# an app version, on the machines, now
ansible-playbook deploy.yml -l env_rc -e app_version_source=manifest \
                            -e app_manifest=2026.09.10-2

# the whole environment's pin
ansible-playbook release.yml -e release_action=rollback \
                             -e release_to_env=prod -e release_tag=2026.09.10-2-prod

# the image
ansible-playbook deploy.yml -e image_action=release -e image_latest=false \
                            -e image_id=ocid1.image.oc1...
```

### Deploying, in detail

On the machine:

```
/srv/apps/<app>/releases/<version>/   the artifact, never written to
/srv/apps/<app>/shared/               state that outlives a release
/srv/apps/<app>/current -> releases/<version>
```

`current` is switched by an atomic symlink replacement, then the unit is
restarted and has to answer on its own port. If it does not, the play puts
`current` back, restarts the previous release, and fails with the last 50
journal lines.

Tarballs are packed from *inside* the publish directory —
`tar -C out -czf app.tar.gz .`. A tarball built from the parent unpacks one
level too deep, and the role says so rather than failing obscurely later.

### A scratch machine

Tag a VM `pscloud.role = app` and the dynamic inventory picks it up —
`site.yml` and `deploy.yml` work against it unchanged. Give it
`pscloud_pool = scratch` so it stays out of the load balancer, and never build
an image from it.

```sh
ansible-playbook site.yml   -l 10.20.16.9
ansible-playbook deploy.yml -l 10.20.16.9 -e app_artifact_source=github \
                            -e app_version=2026.09.12-1
```

That last line is the escape hatch: straight from a private GitHub release, no
CI round trip, for when you are validating a component rather than shipping.

## Checking a machine

```sh
systemctl status 'dotnet-app@*'
systemctl cat dotnet-app@pixapi           # template + both drop-ins, with their sources
systemd-cgtop -m /apps.slice              # memory per app against its ceiling
journalctl -u dotnet-app@pixapi -f

curl -s localhost/healthz                             # what the load balancer asks
curl -s localhost:8081/nginx_status                   # connections and request counters
curl -s localhost:2020/api/v1/metrics | jq            # in_records vs out_records vs retries
cat /run/instance.env                                 # OCI identity used as metric labels
ls /var/lib/node_exporter/textfile/                   # per-app cgroup metrics

/opt/dotnet/5.0.15/dotnet --list-runtimes             # one version per root, by design
/opt/dotnet/2.1.30/dotnet --list-runtimes
```

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
  thread per core per process; nine processes on two cores would mean eighteen
  heaps competing for 4.4 GB.
