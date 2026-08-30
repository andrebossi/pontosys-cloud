# app_canary

Traffic switching between two OCI instance pools. **Only the operations** — it
doesn't evaluate metrics, doesn't decide anything on its own.

Terraform creates `pool-stable` and `pool-canary` pointing to the **same
backend set**. The traffic split comes from each backend's `weight`, which is
the only percentage primitive the OCI LB offers — there's no split between
backend sets, and no off-the-shelf tool (Argo Rollouts, Flagger) speaks to an
OCI VM.

## Usage

```bash
ansible-playbook deploy.yml -e canary_action=up                       # brings up 1 drained canary VM
ansible-playbook deploy.yml -e canary_action=shift -e canary_percent=10
ansible-playbook deploy.yml -e canary_action=shift -e canary_percent=50
ansible-playbook deploy.yml -e canary_action=promote                  # stable takes over the canary's image
ansible-playbook deploy.yml -e canary_action=abort                    # back to 100% on stable
```

Directly on the monitoring VM:

```bash
canary status
canary up --size 1
canary shift 25
canary promote
```

## Weights

`weight` is an integer from 1 to 100 — **0 doesn't exist**. That's why 0% and
100% are expressed via `drain`, not weight. With 2 stable and 1 canary:

| shift | stable (each) | canary | actual traffic |
|---|---|---|---|
| 0 | 1 | drain | 0% |
| 10 | 45 | 10 | 10.0% |
| 25 | 38 | 25 | 24.8% |
| 50 | 25 | 50 | 50.0% |
| 90 | 5 | 90 | 90.0% |
| 100 | drain | 1 | 100% |

`shift` **reconciles**: it recomputes the whole map and writes only what
diverged. An instance replaced by the pool comes back with weight 1 and would
silently break the ramp.

## promote

The stable pool switches to the canary's instance configuration and is
recreated. The canary is only torn down **afterwards** — reversing the order
would leave a gap with nobody serving.

## Authentication

Instance principal, no key on disk: the monitoring VM is in the
`pscloud-dg-monitoring` dynamic group, which has `manage instance-pools` and
`manage load-balancers` on the compartment. Outside of it, use `--profile DEFAULT`.
