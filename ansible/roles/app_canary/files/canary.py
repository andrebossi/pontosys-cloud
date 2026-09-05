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
  canary gate --window 10m
  canary promote
  canary abort
"""

import argparse
import json
import sys
import urllib.parse
import urllib.request

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


class Gate:
    """Does the canary look worse than stable?

    Reads VictoriaMetrics rather than the load balancer, because the question
    is about what the applications ANSWERED, not about whether the backend is
    reachable. The `pool` label comes from /run/instance.env, which the agent
    reads at start -- the value is written into the instance configuration's
    metadata by `image release`, so canary and stable are distinguishable in
    the series without anything else having to know about the rollout.

    This is the piece that turns `canary shift` from something a person runs
    into something a pipeline runs.
    """

    def __init__(self, url, window):
        self.url = url.rstrip("/")
        self.w = window

    def _query(self, expr):
        u = f"{self.url}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
        with urllib.request.urlopen(u, timeout=15) as r:
            body = json.load(r)
        if body.get("status") != "success":
            raise RuntimeError(f"query failed: {body}")
        res = body["data"]["result"]
        if not res:
            return None
        return float(res[0]["value"][1])

    def requests(self, pool):
        return self._query(
            f'sum(increase(nginx_requests{{pool="{pool}"}}[{self.w}]))'
        ) or 0.0

    def error_rate(self, pool):
        """5xx as a share of all answers. None when the pool served nothing."""
        total = self._query(f'sum(rate(nginx_requests{{pool="{pool}"}}[{self.w}]))')
        if not total:
            return None
        bad = self._query(
            f'sum(rate(nginx_requests{{pool="{pool}",status=~"5.."}}[{self.w}]))'
        ) or 0.0
        return bad / total

    def latency_p95(self, pool):
        """None when the histogram has no samples for this pool yet."""
        return self._query(
            "histogram_quantile(0.95, sum(rate("
            f'nginx_request_duration_seconds_bucket{{pool="{pool}"}}[{self.w}]'
            ")) by (le))"
        )

    def evaluate(self, min_requests, max_error_rate, max_error_delta, max_latency_ratio):
        c_req = self.requests("canary")
        c_err = self.error_rate("canary")
        s_err = self.error_rate("stable")
        c_p95 = self.latency_p95("canary")
        s_p95 = self.latency_p95("stable")

        report = {
            "window": self.w,
            "canary_requests": c_req,
            "canary_error_rate": c_err,
            "stable_error_rate": s_err,
            "canary_p95": c_p95,
            "stable_p95": s_p95,
        }
        fail = []

        # Too little traffic is NOT a pass. A canary that served nine requests
        # proves nothing, and treating "no errors seen" as success is how a
        # broken release gets promoted at 3am.
        if c_req < min_requests:
            fail.append(
                f"only {c_req:.0f} requests in {self.w}, need {min_requests} "
                "to say anything -- ramp further or wait"
            )

        if c_err is None:
            if c_req >= min_requests:
                fail.append("canary served requests but has no error-rate series")
        else:
            if c_err > max_error_rate:
                fail.append(f"canary 5xx {c_err:.2%} over the {max_error_rate:.2%} ceiling")
            # Compared against stable as well as against the ceiling: a release
            # is only bad if it is worse than what it replaces. A 4% baseline
            # on both sides is a pre-existing problem, not a regression.
            if s_err is not None and c_err > s_err + max_error_delta:
                fail.append(
                    f"canary 5xx {c_err:.2%} vs stable {s_err:.2%}, "
                    f"worse by more than {max_error_delta:.2%}"
                )

        if c_p95 and s_p95 and s_p95 > 0:
            ratio = c_p95 / s_p95
            report["p95_ratio"] = ratio
            if ratio > max_latency_ratio:
                fail.append(
                    f"canary p95 {c_p95:.3f}s is {ratio:.2f}x stable "
                    f"{s_p95:.3f}s, over {max_latency_ratio:.2f}x"
                )

        report["failures"] = fail
        return report


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--compartment-id", required=True)
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--profile", help="~/.oci/config profile; omitted uses instance principal")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    up = sub.add_parser("up"); up.add_argument("--size", type=int, default=1)
    sh = sub.add_parser("shift"); sh.add_argument("percent", type=float, help="0 to 100")
    g = sub.add_parser("gate", help="compare canary against stable and exit non-zero if worse")
    g.add_argument("--metrics-url", default="http://127.0.0.1:8428")
    g.add_argument("--window", default="10m")
    g.add_argument("--min-requests", type=float, default=200)
    g.add_argument("--max-error-rate", type=float, default=0.02)
    g.add_argument("--max-error-delta", type=float, default=0.01)
    g.add_argument("--max-latency-ratio", type=float, default=1.5)
    sub.add_parser("promote")
    sub.add_parser("abort")
    a = p.parse_args()

    # The gate reads metrics only -- it never touches the load balancer, so it
    # does not need the compartment or a pool to exist.
    if a.cmd == "gate":
        r = Gate(a.metrics_url, a.window).evaluate(
            a.min_requests, a.max_error_rate, a.max_error_delta, a.max_latency_ratio
        )

        def pct(v):
            return "n/a" if v is None else f"{v:.2%}"

        def sec(v):
            return "n/a" if v is None else f"{v:.3f}s"

        print(f"window          : {r['window']}")
        print(f"canary requests : {r['canary_requests']:.0f}")
        print(f"5xx  canary     : {pct(r['canary_error_rate'])}")
        print(f"5xx  stable     : {pct(r['stable_error_rate'])}")
        print(f"p95  canary     : {sec(r['canary_p95'])}")
        print(f"p95  stable     : {sec(r['stable_p95'])}")
        if r["failures"]:
            print("\nGATE FAILED")
            for f in r["failures"]:
                print(f"  - {f}")
            sys.exit(1)
        print("\ngate passed")
        return

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
