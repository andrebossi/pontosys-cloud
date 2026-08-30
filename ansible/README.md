# Ansible

## Where each variable lives

```
group_vars/all.yml              → every VM
group_vars/role_app.yml         → instance pool VMs
group_vars/role_db.yml          → MariaDB VM
group_vars/role_monitoring.yml  → observability-backend VM
host_vars/<private ip>.yml      → a single machine
```

The `role_*` groups come from the dynamic inventory, which derives them from
the `pscloud.role` tag applied by Terraform. There is no static inventory:
instance pool VMs have no stable name or IP, and a fixed file would go stale
on the first scale-out.

Rule: if a value is true for the whole role, it goes in `group_vars/role_*`.
If it's true for a single machine, it goes in `host_vars/`. No `when: role ==
'db'` scattered across tasks.

## Adding a Fluent Bit collection

A dictionary in the right list. No task changes.

```yaml
# group_vars/role_db.yml — applies to every database VM
fluentbit_inputs_role:
  - name: tail
    tag: custom.audit
    path: /var/log/audit/audit.log
    parser: syslog-rfc5424
    db: /var/lib/fluent-bit/audit.db

fluentbit_outputs_role:
  - name: loki
    match: custom.audit
    host: "{{ monitoring_private_ip }}"
    port: 9428
    uri: /insert/loki/api/v1/push
    labels: job=audit,instance=${INSTANCE_NAME}
```

The lists are merged in this order: `_common` (all.yml) + `_role` (group_vars) +
`_host` (host_vars). They are never replaced, only appended.

If the parser is new, add it to
`roles/observability_agent/templates/parsers.yaml.j2`.

The template is validated with `fluent-bit --dry-run` **before** being
written: a broken config never reaches disk and the agent keeps running with
the last good one.

## Adding an application

Two edits, in this order:

1. `infra/live/prod/env.hcl` → `locals.applications` (Terraform creates the
   MariaDB user with a random password and writes the DSN to OCI Vault);
2. `ansible/group_vars/role_app.yml` → `applications` (Ansible creates the
   schema, applies the per-schema `GRANT`, writes the env file and the
   nginx `server block`).

Keeping these two in sync is the only manual coupling between Terraform and
Ansible. No module, role, or template changes.

## Running it

```bash
ansible-galaxy collection install -r requirements.yml

export OCI_COMPARTMENT_OCID=ocid1.compartment.oc1..xxx
export OCI_VAULT_OCID=ocid1.vault.oc1.sa-saopaulo-1.xxx

ansible-inventory --graph          # check that the role_* groups showed up
ansible-playbook site.yml --check  # dry run
ansible-playbook site.yml
```

The monitoring VM is the only host with a public IP and acts as the jump
host into the private subnets (see `ansible.cfg`).

## Checking collection on a VM

```bash
curl -s http://127.0.0.1:2020/api/v1/metrics | jq .   # in_records vs out_records vs retries
cat /run/instance.env                                  # OCI identity (role, FD, shape)
ls /var/lib/node_exporter/textfile/                     # active textfile exporters
journalctl -u fluent-bit -n 50
```
