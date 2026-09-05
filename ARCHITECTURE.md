# Architecture

OCI, region `sa-saopaulo-1`. A new VCN carries the platform; an existing VCN
(`10.0.0.0/16`, the rustdesk network) is reached over a local peering gateway.
Two environments share it: `prod` owns the network, the database and the
application tier; `rc` adds test machines and a second load balancer on top of
the same network.

```
                        Internet
                            │
              ┌─────────────┴──────────────┐
              │                            │
        ┌─────▼──────┐              ┌──────▼─────┐
        │  prod LB   │              │   rc LB    │      separate public IPs
        │ flexible   │              │ flexible   │
        └─────┬──────┘              └──────┬─────┘
              │      sn-public 10.20.0.0/24│            route table: IGW
  ────────────┼────────────────────────────┼──────────────────────────────
              │                            │
     ┌────────▼─────────┐          ┌───────▼────────┐
     │  instance pool   │          │  rc instances  │
     │  stable 2..6     │          │  fixed count   │
     │  autoscale CPU   │          └────────────────┘
     │  canary 0        │
     └────────┬─────────┘  sn-app 10.20.16.0/20       route table: NAT + SGW
  ────────────┼──────────────────────────────────────────────────────────
              │ 3306
     ┌────────▼─────────┐
     │  MySQL DB System │  sn-db 10.20.32.0/24        route table: SGW only
     │  private, no NLB │                             no default route
     └──────────────────┘

     LPG ─────────────► existing VCN 10.0.0.0/16 (reaches the app tier,
                        the app tier pushes metrics back)
```

## Environments

| | prod | rc |
|---|---|---|
| network, peering | creates | uses prod's |
| identity, platform | creates | uses prod's |
| database | creates | uses prod's |
| machines | instance pool with autoscaling | fixed instances |
| load balancer | its own | its own, second public IP |

`rc` units point at `../../prod/<unit>` through `dependency` blocks. Nothing is
duplicated: one network, one database, one vault, two sets of machines.

## State

One state file per unit, keyed by its path under `live/`:

```
prod/network/terraform.tfstate      rc/compute/terraform.tfstate
prod/database/terraform.tfstate     rc/loadbalancer/terraform.tfstate
```

An apply on the application tier never puts the network or the database in the
plan, and a unit can be destroyed on its own.

Dependency order, resolved by Terragrunt from the `dependency` blocks:

```
network → peering
        → platform → database → app-tier
        → identity ────────────┘
```

## Networking

**One route table per subnet.** In OCI a subnet has exactly one route table, so
it is the unit of routing: the public subnet defaults to the internet gateway,
the app subnet to the NAT gateway, and the database subnet has **no default
route at all** — only the service gateway and the peering route. A shared table
would have handed the database internet egress it has no use for.

**NSGs, not security lists.** The default security list is emptied. Rules
reference other NSGs by name (`app` talks to `db` on 3306) instead of CIDRs, so
an instance created by a scale-out inherits its permissions the moment it joins
the NSG. Three groups: `lb`, `app`, `db`.

**Peering.** A local peering gateway on each side connects the new VCN to the
existing one. Both sides route the other's CIDR through it. The route table for
the far side is created but not attached to any subnet yet — attaching it
replaces whatever route table that subnet has today, so it needs to carry the
existing internet route as well.

A gateway belongs to exactly one VCN and cannot be borrowed by another, which is
why the new VCN creates its own internet and NAT gateways rather than reusing
`ig-rustdesk`.

## Compute

The application tier is an instance configuration plus two instance pools,
`stable` and `canary`, both behind one flexible load balancer. Autoscaling grows
`stable` from 2 to 6 on CPU — out above 70%, in below 25%, five-minute pending
duration, five-minute cooldown. `canary` stays at 0 until a release moves
traffic to it.

The load balancer health check (`/healthz`) only removes a backend from
rotation; the pool is what replaces a dead instance. `/healthz` deliberately
does not touch the database, so a database outage does not fail every backend at
once.

Instances boot from a Packer image when `PSCLOUD_APP_IMAGE_ID` is set, and from
the newest Ubuntu platform image otherwise.

## Identity and secrets

A defined tag namespace (`pscloud.*`) carries seven keys: `role`, `tier`,
`environment`, `data_classification`, `backup`, `cost_center`, `owner`.
`environment` and `cost_center` are cost-tracking.

Defined tags, not freeform, for two reasons: an IAM dynamic group rule can only
match a defined tag, and a defined tag can validate its values — `role = db`
applies, `role = database` fails in the plan instead of producing an instance
that silently belongs to no dynamic group.

That single `pscloud.role` tag drives three things: the IAM dynamic group, the
Ansible inventory grouping, and the policy that lets an instance read its own
secrets. The monitoring VM lives outside this repository; tagging it
`pscloud.role = monitoring` is all it needs to pick up its policy.

The platform unit generates every credential — SSH keys per role, the database
admin password, one password per application — and writes them to OCI Vault. The
applications' DSN points at the database's DNS name
(`pscloudmysql.db.vcn.oraclevcn.com`), which is deterministic from the labels, so
the secret can be written before the database exists and survives it being
replaced. Terraform generates, Ansible reads through the instance principal,
nothing lands in git.

## Modules

Generic, driven entirely by inputs, no environment values inside.

| Module | Builds |
|---|---|
| `network` | VCN (create or adopt), subnets, one route table each, gateways, NSGs and rules |
| `peering` | local peering gateway on an existing VCN, and its route table |
| `identity` | tag namespace, dynamic groups, policies |
| `platform` | vault, KMS key, SSH keys, secrets, bastion, backup bucket |
| `database` | MySQL DB System, optional network load balancer |
| `app-tier` | load balancer, instance configuration, stable and canary pools, autoscaling |
| `compute` | plain instances from a map |
| `loadbalancer` | load balancer, backend set, listeners |

`vm` and `cloud-init` are still present; no unit uses `vm` today.

## Known gaps

- Nothing has been applied end to end from this checkout; what is verified is
  `terraform validate` on every module with the units' real inputs,
  `terragrunt hcl validate` across the tree, and the dependency graph.
- The peer-side route table is not attached to the existing subnet.
- The load balancer has an HTTP listener only; the HTTPS one appears when
  `lb_certificate` is set.
- Database schemas and users are created by Ansible, not Terraform — the DB
  system is private and unreachable from where Terraform runs.
