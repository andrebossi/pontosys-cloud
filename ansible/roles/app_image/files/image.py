#!/usr/bin/env python3
"""Ciclo de vida da imagem dourada, com o SDK da OCI.

Roda na VM de monitoramento e usa a identidade da própria máquina (instance
principal) -- não há chave de API em disco.

É a ponte entre o Packer e o canário: o Packer produz a imagem, `release`
transforma essa imagem numa instance configuration e aponta o pool canário para
ela, e o `canary` cuida do tráfego.

  image list
  image release --image-id ocid1.image... [--pool canary]
  image release --latest
  image prune [--keep 3]
"""

import argparse
import copy
import sys
import time

import oci

FAMILY_TAG = "pscloud_family"
BUILT_BY_TAG = "pscloud_built_by"
RELEASE_TAG = "pscloud_release"
COMPONENT_TAG = "pscloud_component"
POOL_TAG = "pscloud_pool"


def client_kwargs(profile):
    if profile:
        return {"config": oci.config.from_file(profile_name=profile)}
    return {
        "config": {},
        "signer": oci.auth.signers.InstancePrincipalsSecurityTokenSigner(),
    }


class Images:
    def __init__(self, compartment_id, family, profile=None):
        self.c = compartment_id
        self.family = family
        kw = client_kwargs(profile)
        self.compute = oci.core.ComputeClient(**kw)
        self.cm = oci.core.ComputeManagementClient(**kw)

    def list(self):
        """Imagens da família, mais novas primeiro."""
        out = []
        for i in oci.pagination.list_call_get_all_results(
            self.compute.list_images, compartment_id=self.c, sort_by="TIMECREATED", sort_order="DESC"
        ).data:
            t = i.freeform_tags or {}
            if t.get(FAMILY_TAG) == self.family and t.get(BUILT_BY_TAG) == "packer":
                if i.lifecycle_state == "AVAILABLE":
                    out.append(i)
        return out

    def pools(self):
        out = {}
        for p in oci.pagination.list_call_get_all_results(
            self.cm.list_instance_pools, compartment_id=self.c
        ).data:
            t = p.freeform_tags or {}
            if t.get(COMPONENT_TAG) == "app-pool" and p.lifecycle_state != "TERMINATED":
                out[t.get(POOL_TAG)] = p
        return out

    def pool_image(self, pool):
        ic = self.cm.get_instance_configuration(pool.instance_configuration_id).data
        return ic, ic.instance_details.launch_details.source_details.image_id

    # -- release ----------------------------------------------------------
    def release(self, image_id, pool_name):
        """Clona a instance configuration do pool trocando só a imagem.

        Instance configuration é imutável na OCI: não dá para editar, só criar
        outra. Clonar a que já existe em vez de montar do zero preserva shape,
        subnet, NSG, cloud-init e tags -- errar um desses só apareceria quando a
        instância subisse quebrada.
        """
        pools = self.pools()
        if pool_name not in pools:
            sys.exit(f"pool '{pool_name}' não encontrado (tags {COMPONENT_TAG}=app-pool, {POOL_TAG}={pool_name})")
        pool = pools[pool_name]

        img = self.compute.get_image(image_id).data
        release = (img.freeform_tags or {}).get(RELEASE_TAG, img.display_name)

        src_ic, current = self.pool_image(pool)
        if current == image_id:
            return f"pool {pool_name} já usa {image_id}, nada a fazer"

        details = copy.deepcopy(src_ic.instance_details)
        details.launch_details.source_details.image_id = image_id
        details.launch_details.display_name = f"{pool.display_name}"
        md = dict(details.launch_details.metadata or {})
        # O cloud-init lê estas duas para rotular a métrica: sem elas o canário
        # e o estável ficam indistinguíveis no VictoriaMetrics.
        md[POOL_TAG] = pool_name
        md[RELEASE_TAG] = release
        details.launch_details.metadata = md

        new_ic = self.cm.create_instance_configuration(
            oci.core.models.CreateInstanceConfigurationDetails(
                compartment_id=self.c,
                display_name=f"{pool.display_name}-{release}",
                instance_details=details,
                freeform_tags={COMPONENT_TAG: "app-ic", RELEASE_TAG: release, POOL_TAG: pool_name},
            )
        ).data

        self.cm.update_instance_pool(
            pool.id,
            oci.core.models.UpdateInstancePoolDetails(instance_configuration_id=new_ic.id),
        )
        return (f"pool {pool_name} -> {new_ic.id}\n"
                f"  imagem  {image_id} ({release})\n"
                f"  próximo: canary up && canary shift 10")

    # -- prune ------------------------------------------------------------
    def prune(self, keep, min_age_seconds, dry_run):
        """Mantém as N mais novas. Só data não basta: a imagem em produção pode
        ser mais antiga que vários builds que falharam depois dela."""
        imgs = self.list()
        protected = {i.id for i in imgs[:keep]}
        for name, pool in self.pools().items():
            try:
                protected.add(self.pool_image(pool)[1])
            except Exception:
                pass

        now = time.time()
        targets = [
            i for i in imgs
            if i.id not in protected
            and (now - i.time_created.timestamp()) > min_age_seconds
        ]
        for i in targets:
            print(f"  {'(dry-run) ' if dry_run else ''}apagando {i.display_name}")
            if not dry_run:
                self.compute.delete_image(i.id)
        return f"{len(imgs)} imagens, {len(protected)} protegidas, {len(targets)} removidas"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--compartment-id", required=True)
    p.add_argument("--family", default="app")
    p.add_argument("--profile", help="perfil do ~/.oci/config; omitido usa instance principal")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list")

    rel = sub.add_parser("release")
    g = rel.add_mutually_exclusive_group(required=True)
    g.add_argument("--image-id")
    g.add_argument("--latest", action="store_true")
    rel.add_argument("--pool", default="canary")

    pr = sub.add_parser("prune")
    pr.add_argument("--keep", type=int, default=3)
    pr.add_argument("--min-age-seconds", type=int, default=7200)
    pr.add_argument("--dry-run", action="store_true")

    a = p.parse_args()
    im = Images(a.compartment_id, a.family, a.profile)

    if a.cmd == "list":
        pools = im.pools()
        in_use = {}
        for n, pool in pools.items():
            try:
                in_use[im.pool_image(pool)[1]] = n
            except Exception:
                pass
        for i in im.list():
            mark = f"  <- pool {in_use[i.id]}" if i.id in in_use else ""
            rel = (i.freeform_tags or {}).get(RELEASE_TAG, "-")
            print(f"{i.time_created:%Y-%m-%d %H:%M}  {rel:<20} {i.id}{mark}")

    elif a.cmd == "release":
        image_id = a.image_id
        if a.latest:
            imgs = im.list()
            if not imgs:
                sys.exit(f"nenhuma imagem da família '{a.family}' construída pelo Packer")
            image_id = imgs[0].id
        print(im.release(image_id, a.pool))

    elif a.cmd == "prune":
        print(im.prune(a.keep, a.min_age_seconds, a.dry_run))


if __name__ == "__main__":
    main()
