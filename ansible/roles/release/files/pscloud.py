#!/usr/bin/env python3
"""Artifacts and version manifests, on OCI Object Storage.

The bucket and nothing else. Rolling a release out is Ansible with a --limit,
run by hand from a pipeline -- there is no orchestration in here, deliberately.

Runs with the identity of the machine it is on (instance principal), or with an
API-key profile when run from a laptop -- there is no key on disk in the first
case.

  bucket layout
    artifacts/<name>/<name>-<version>.tar.gz   apps, and the fonts/webroot bundles
    manifests/<env>/current.json               what <env> runs now
    manifests/<env>/<release>.json             history, for rollback

  pscloud push pixapi 1.4.0 ./pixapi.tar.gz
  pscloud latest pixapi
  pscloud show rc [--json]
  pscloud list rc
  pscloud publish rc --release 2026.09.12-1 --apps pixapi=1.4.0,virtualstore=2.9.1
  pscloud promote --from rc --to prod
  pscloud rollback prod --release 2026.09.10-2
  pscloud par artifacts/pixapi/pixapi-1.4.0.tar.gz --ttl 600
"""

import argparse
import datetime as dt
import json
import re
import sys

import oci

MANIFESTS = "manifests"
ARTIFACTS = "artifacts"


def auth(profile):
    if profile:
        return {"config": oci.config.from_file(profile_name=profile)}
    return {
        "config": {},
        "signer": oci.auth.signers.InstancePrincipalsSecurityTokenSigner(),
    }


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


class Store:
    def __init__(self, bucket, profile=None):
        self.os = oci.object_storage.ObjectStorageClient(**auth(profile))
        self.bucket = bucket
        self.ns = self.os.get_namespace().data
        self.endpoint = self.os.base_client.endpoint.rstrip("/")

    def get(self, name):
        return self.os.get_object(self.ns, self.bucket, name).data.content

    def put(self, name, body, content_type="application/octet-stream"):
        self.os.put_object(self.ns, self.bucket, name, body, content_type=content_type)
        return name

    def names(self, prefix):
        out, start = [], None
        while True:
            r = self.os.list_objects(
                self.ns, self.bucket, prefix=prefix, fields="name,timeCreated", start=start
            ).data
            out.extend(r.objects)
            if not r.next_start_with:
                break
            start = r.next_start_with
        return out

    def exists(self, name):
        try:
            self.os.head_object(self.ns, self.bucket, name)
            return True
        except oci.exceptions.ServiceError as e:
            if e.status == 404:
                return False
            raise

    @staticmethod
    def artifact_name(app, version):
        return f"{ARTIFACTS}/{app}/{app}-{version}.tar.gz"

    def versions(self, app):
        # Sorted by upload time, not by name: sorting version strings lexically
        # puts 1.10 before 1.9.
        pat = re.compile(rf"^{re.escape(ARTIFACTS)}/{re.escape(app)}/{re.escape(app)}-(.+)\.tar\.gz$")
        found = []
        for o in self.names(f"{ARTIFACTS}/{app}/"):
            m = pat.match(o.name)
            if m:
                found.append((o.time_created, m.group(1)))
        return [v for _, v in sorted(found, reverse=True)]

    def par(self, object_name, ttl_seconds):
        # A read-only, single-object, short-lived URL. This is what lets an
        # application VM download an artifact over plain HTTP with no OCI
        # tooling and no credential of its own.
        if not self.exists(object_name):
            sys.exit(f"object not found: {object_name}")
        d = oci.object_storage.models.CreatePreauthenticatedRequestDetails(
            name=f"deploy-{now().strftime('%Y%m%dT%H%M%S')}",
            object_name=object_name,
            access_type="ObjectRead",
            time_expires=now() + dt.timedelta(seconds=ttl_seconds),
        )
        r = self.os.create_preauthenticated_request(self.ns, self.bucket, d).data
        return self.endpoint + r.access_uri

    @staticmethod
    def manifest_name(env, release="current"):
        return f"{MANIFESTS}/{env}/{release}.json"

    def manifest(self, env, release="current"):
        name = self.manifest_name(env, release)
        return json.loads(self.get(name)) if self.exists(name) else None

    def write_manifest(self, env, manifest):
        body = json.dumps(manifest, indent=2, sort_keys=True).encode()
        # History first, then current: a crash between the two leaves an
        # unreferenced history entry, which is harmless. The reverse would
        # leave `current` pointing at a release with no record.
        self.put(self.manifest_name(env, manifest["release"]), body, "application/json")
        self.put(self.manifest_name(env), body, "application/json")
        return manifest

    def manifests(self, env):
        out = []
        for o in self.names(f"{MANIFESTS}/{env}/"):
            tag = o.name.rsplit("/", 1)[-1][:-5]
            if tag != "current":
                out.append((o.time_created, tag))
        return [t for _, t in sorted(out, reverse=True)]


def parse_apps(spec):
    out = {}
    for part in filter(None, (p.strip() for p in spec.split(","))):
        if "=" not in part:
            sys.exit(f"--apps expects name=version, got {part!r}")
        k, v = part.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--bucket", required=True)
    p.add_argument("--profile", help="~/.oci/config profile; omitted uses instance principal")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("show"); s.add_argument("env")
    s.add_argument("--release", default="current"); s.add_argument("--json", action="store_true")

    s = sub.add_parser("list"); s.add_argument("env")
    s = sub.add_parser("latest"); s.add_argument("app")

    s = sub.add_parser("publish"); s.add_argument("env")
    s.add_argument("--release", required=True)
    s.add_argument("--apps", required=True, help="name=version,name=version")
    s.add_argument("--base-commit", default="")

    s = sub.add_parser("promote")
    s.add_argument("--from", dest="src", required=True)
    s.add_argument("--to", dest="dst", required=True)

    s = sub.add_parser("rollback"); s.add_argument("env"); s.add_argument("--release", required=True)

    s = sub.add_parser("par"); s.add_argument("object"); s.add_argument("--ttl", type=int, default=900)

    s = sub.add_parser("push")
    s.add_argument("app"); s.add_argument("version"); s.add_argument("file")

    a = p.parse_args()

    st = Store(a.bucket, a.profile)

    if a.cmd == "show":
        m = st.manifest(a.env, a.release)
        if m is None:
            sys.exit(f"no manifest {a.release} for {a.env}")
        if a.json:
            print(json.dumps(m))
        else:
            print(f"env      : {a.env}")
            print(f"release  : {m['release']}")
            print(f"created  : {m.get('created', '?')}")
            print(f"base     : {m.get('base_commit') or '(not recorded)'}")
            for app, ver in sorted(m["apps"].items()):
                print(f"  {app:<24} {ver}")

    elif a.cmd == "list":
        cur = (st.manifest(a.env) or {}).get("release")
        for tag in st.manifests(a.env):
            print(f"{'*' if tag == cur else ' '} {tag}")

    elif a.cmd == "latest":
        v = st.versions(a.app)
        if not v:
            sys.exit(f"no artifact for {a.app} in {a.bucket}")
        print(v[0])

    elif a.cmd == "publish":
        apps = parse_apps(a.apps)
        missing = [f"{k}={v}" for k, v in apps.items() if not st.exists(st.artifact_name(k, v))]
        if missing:
            sys.exit("not in the bucket: " + ", ".join(missing))
        m = st.write_manifest(a.env, {
            "release": a.release, "env": a.env, "created": now().isoformat(),
            "base_commit": a.base_commit, "apps": apps,
        })
        print(f"{a.env} -> {m['release']} ({len(apps)} apps)")

    elif a.cmd == "promote":
        src = st.manifest(a.src)
        if src is None:
            sys.exit(f"{a.src} has no current manifest -- deploy it first")
        # Versions copied verbatim: prod runs what rc validated, not a fresh
        # resolution of "latest" that could have moved since.
        m = dict(src)
        m["env"] = a.dst
        m["release"] = f"{src['release']}-{a.dst}"
        m["created"] = now().isoformat()
        m["promoted_from"] = f"{a.src}/{src['release']}"
        st.write_manifest(a.dst, m)
        print(f"{a.src}/{src['release']} -> {a.dst}/{m['release']} ({len(m['apps'])} apps)")

    elif a.cmd == "rollback":
        m = st.manifest(a.env, a.release)
        if m is None:
            sys.exit(f"no manifest {a.release} for {a.env}")
        st.put(st.manifest_name(a.env),
               json.dumps(m, indent=2, sort_keys=True).encode(), "application/json")
        print(f"{a.env} current -> {a.release}")

    elif a.cmd == "par":
        print(st.par(a.object, a.ttl))

    elif a.cmd == "push":
        name = st.artifact_name(a.app, a.version)
        with open(a.file, "rb") as fh:
            st.put(name, fh)
        print(name)


if __name__ == "__main__":
    main()
