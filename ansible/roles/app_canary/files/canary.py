#!/usr/bin/env python3
"""OCI instance pool canary. Only the traffic-shifting operations.

The two pools (stable and canary) register in the SAME load balancer backend
set, and the traffic split comes from each backend's `weight` -- it's the
only percentage primitive the OCI LB has.

Weight is an integer from 1 to 100: 0 doesn't exist. That's why 0% and 100%
are expressed with `drain`, not with weight.

  canary status
  canary up [--size N]
  canary shift 25
  canary promote
  canary abort
"""

import argparse
import sys

import oci

TAG_COMPONENT = "pscloud_component"
TAG_POOL = "pscloud_pool"


class Canary:
    def __init__(self, compartment_id, port, profile=None):
        self.c = compartment_id
        self.port = port
        if profile:
            cfg = oci.config.from_file(profile_name=profile)
            kw = {"config": cfg}
        else:
            # There's no API key on disk on the monitoring VM: the identity
            # comes from the instance principal, authorized via the dynamic group.
            kw = {"config": {}, "signer": oci.auth.signers.InstancePrincipalsSecurityTokenSigner()}
        self.cm = oci.core.ComputeManagementClient(**kw)
        self.compute = oci.core.ComputeClient(**kw)
        self.vnet = oci.core.VirtualNetworkClient(**kw)
        self.lb = oci.load_balancer.LoadBalancerClient(**kw)
        self._discover()

    # -- discovery ----------------------------------------------------------
    def _discover(self):
        """Finds the resources via the freeform tags applied by Terraform."""
        pools = {}
        for p in oci.pagination.list_call_get_all_results(
            self.cm.list_instance_pools, compartment_id=self.c
        ).data:
            t = p.freeform_tags or {}
            if t.get(TAG_COMPONENT) == "app-pool" and p.lifecycle_state != "TERMINATED":
                pools[t.get(TAG_POOL)] = p

        lbs = [
            b for b in oci.pagination.list_call_get_all_results(
                self.lb.list_load_balancers, compartment_id=self.c
            ).data
            if (b.freeform_tags or {}).get(TAG_COMPONENT) == "app-lb"
        ]
        if "stable" not in pools or "canary" not in pools or not lbs:
            sys.exit("could not find both instance pools and the load balancer. run the 60-apps stack first.")

        self.stable, self.canary = pools["stable"], pools["canary"]
        self.lb_id = lbs[0].id
        self.bes = next(iter(self.lb.get_load_balancer(self.lb_id).data.backend_sets))

    def _ips(self, pool):
        ips = []
        for inst in oci.pagination.list_call_get_all_results(
            self.cm.list_instance_pool_instances,
            compartment_id=self.c,
            instance_pool_id=pool.id,
        ).data:
            if inst.state != "Running":
                continue
            for att in self.compute.list_vnic_attachments(
                compartment_id=self.c, instance_id=inst.id
            ).data:
                vnic = self.vnet.get_vnic(att.vnic_id).data
                if vnic.private_ip:
                    ips.append(vnic.private_ip)
        return ips

    def _backends(self):
        return {b.name: b for b in self.lb.get_backend_set(self.lb_id, self.bes).data.backends}

    # -- weights --------------------------------------------------------------
    @staticmethod
    def plan(share, stable, canary):
        """share (0.0-1.0) -> {backend: (weight, drain)}."""
        if share <= 0:
            return {**{n: (1, False) for n in stable}, **{n: (1, True) for n in canary}}
        if share >= 1:
            return {**{n: (1, True) for n in stable}, **{n: (1, False) for n in canary}}
        ws = max(1, min(100, round(100 * (1 - share) / max(1, len(stable)))))
        wc = max(1, min(100, round(100 * share / max(1, len(canary)))))
        return {**{n: (ws, False) for n in stable}, **{n: (wc, False) for n in canary}}

    def shift(self, share):
        """Reconciles the weights. An instance replaced by the pool comes back
        with weight 1; recomputing everything and writing only what diverged
        avoids a broken ramp."""
        st = [f"{ip}:{self.port}" for ip in self._ips(self.stable)]
        cn = [f"{ip}:{self.port}" for ip in self._ips(self.canary)]
        if not st and not cn:
            sys.exit("no backends registered in the backend set.")
        want = self.plan(share, st, cn)
        obs = self._backends()

        changed = 0
        for name, (weight, drain) in want.items():
            cur = obs.get(name)
            if cur is None or (cur.weight == weight and bool(cur.drain) == drain):
                continue
            r = self.lb.update_backend(
                oci.load_balancer.models.UpdateBackendDetails(
                    weight=weight, drain=drain, backup=bool(cur.backup), offline=bool(cur.offline)
                ),
                self.lb_id, self.bes, name,
            )
            self._wait_lb(r.headers["opc-work-request-id"])
            changed += 1

        live = sum(w for w, d in want.values() if not d)
        cw = sum(want[n][0] for n in cn if not want[n][1])
        return {"stable": len(st), "canary": len(cn), "changed": changed,
                "effective": round(cw / live, 3) if live else 0.0}

    def _wait_lb(self, wr_id):
        oci.wait_until(
            self.lb, self.lb.get_work_request(wr_id), "lifecycle_state", "SUCCEEDED",
            max_wait_seconds=300, max_interval_seconds=5,
        )

    # -- pools ------------------------------------------------------------------
    def scale(self, pool, size, wait=True):
        self.cm.update_instance_pool(
            pool.id, oci.core.models.UpdateInstancePoolDetails(size=size)
        )
        if wait:
            oci.wait_until(
                self.cm, self.cm.get_instance_pool(pool.id), "lifecycle_state", "RUNNING",
                max_wait_seconds=900, max_interval_seconds=15,
            )

    def promote(self):
        """The stable pool switches to the canary's instance configuration and
        is recreated. Only afterwards is the canary torn down -- never before,
        or there would be a gap with nobody serving."""
        ic = self.cm.get_instance_pool(self.canary.id).data.instance_configuration_id
        size = self.stable.size or 2

        self.cm.update_instance_pool(
            self.stable.id,
            oci.core.models.UpdateInstancePoolDetails(instance_configuration_id=ic),
        )
        self.scale(self.stable, 0)
        self.scale(self.stable, size)

        self.shift(0.0)
        self.scale(self.canary, 0, wait=False)
        return f"promoted: stable pool recreated with {ic}"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--compartment-id", required=True)
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--profile", help="~/.oci/config profile; omitted uses instance principal")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    up = sub.add_parser("up"); up.add_argument("--size", type=int, default=1)
    sh = sub.add_parser("shift"); sh.add_argument("percent", type=float, help="0 to 100")
    sub.add_parser("promote")
    sub.add_parser("abort")
    a = p.parse_args()

    c = Canary(a.compartment_id, a.port, a.profile)

    if a.cmd == "status":
        st, cn = c._ips(c.stable), c._ips(c.canary)
        print(f"backend set : {c.bes}")
        print(f"stable      : size={c.stable.size} running={len(st)} {st}")
        print(f"canary      : size={c.canary.size} running={len(cn)} {cn}")
        total = 0; cw = 0
        for n, b in sorted(c._backends().items()):
            live = not b.drain and not b.offline
            total += b.weight if live else 0
            if n.split(":")[0] in cn and live:
                cw += b.weight
            print(f"  {n:<24} weight={b.weight:<4} drain={str(b.drain):<5} offline={b.offline}")
        print(f"canary traffic: {cw / total:.1%}" if total else "canary traffic: 0.0%")

    elif a.cmd == "up":
        c.scale(c.canary, a.size)
        print(c.shift(0.0), "-> canary is up and drained, reachable by IP for testing")

    elif a.cmd == "shift":
        r = c.shift(max(0.0, min(100.0, a.percent)) / 100.0)
        print(f"target {a.percent:.0f}% -> effective {r['effective']:.1%} "
              f"({r['stable']} stable, {r['canary']} canary, {r['changed']} backends changed)")

    elif a.cmd == "promote":
        print(c.promote())

    elif a.cmd == "abort":
        print(c.shift(0.0))
        c.scale(c.canary, 0, wait=False)
        print("canary removed, traffic 100% on stable")


if __name__ == "__main__":
    main()
