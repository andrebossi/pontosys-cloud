# host_vars

One file per machine, named after `ansible_host` (the dynamic inventory uses
`hostname_format: private_ip`, so the name is the private IP).

This is for what's true for **one** machine only — and nothing more. Example:

```yaml
# host_vars/10.20.32.10.yml
grafana_admin_password: "{{ vault_grafana_password }}"

# Extra collection for this machine only, added to what comes from all.yml.
fluentbit_inputs_host:
  - name: tail
    tag: custom.audit
    path: /var/log/audit/audit.log
    parser: syslog-rfc5424
    db: /var/lib/fluent-bit/audit.db

fluentbit_outputs_host:
  - name: loki
    match: custom.audit
    host: "{{ monitoring_private_ip }}"
    port: 9428
    uri: /insert/loki/api/v1/push
    labels: job=audit,instance=${INSTANCE_NAME}
```

The `*_host` lists are **added** to `*_common` and `*_role`, never replacing
them — see the comment in `group_vars/all.yml`.
