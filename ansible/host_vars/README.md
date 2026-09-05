# host_vars

One file per machine, named after `ansible_host`. The dynamic inventory uses
`hostname_format: private_ip`, so the name is the private IP.

This is for what is true for **one** machine and nothing more:

```yaml
# host_vars/10.20.16.5.yml

# Extra collection for this machine only, added to what already comes from
# group_vars -- the *_extra_* lists are concatenated, never replaced.
fluentbit_extra_inputs:
  - name: tail
    tag: custom.audit
    path: /var/log/audit/audit.log
    parser: syslog-rfc5424
    db: /var/lib/fluent-bit/audit.db
```

An application-level override belongs in the catalog entry, not here: a limit
that is right for one machine is almost always right for the role.
