# pscloud

Infrastructure for the OCI tenancy in `sa-saopaulo-1`: Terragrunt over Terraform
modules, Ansible for configuration, Packer for the application image.

See [ARCHITECTURE.md](ARCHITECTURE.md) for what gets built and why.

```
infra/bootstrap    state bucket, applied once with local state
infra/modules      generic Terraform modules, no environment values inside
infra/live         Terragrunt: one directory per environment, one state per unit
ansible            configuration, dynamic inventory from the pscloud.role tag
packer             application image
keys               credentials and .env, never committed
```

## Requirements

| Tool | Version | Note |
|---|---|---|
| Terraform | 1.15+ | the `oci` backend exists in Terraform, **not** in OpenTofu |
| Terragrunt | 1.1+ | defaults to `tofu`, so `TG_TF_PATH` has to point at terraform |
| Ansible | 2.16+ | with the `oracle.oci` collection |
| Packer | 1.9+ | only to rebuild the app image |

## Credentials

Everything reads from `keys/.env`, which is gitignored:

```sh
export TF_VAR_tenancy_ocid=ocid1.tenancy.oc1..xxx
export TF_VAR_user_ocid=ocid1.user.oc1..xxx
export TF_VAR_fingerprint=aa:bb:cc:...
export TF_VAR_private_key_path=/home/andre/projects/pscloud/keys/rafael@pontosys.com-private.pem
export TG_TF_PATH=terraform
```

Load it into the shell before any command:

```sh
source keys/.env
```

The OCI provider picks up `TF_VAR_tenancy_ocid`, `TF_VAR_user_ocid`,
`TF_VAR_fingerprint` and `TF_VAR_private_key_path` on its own — that is why the
generated `provider.tf` only sets the region. `TG_TF_PATH=terraform` is what
keeps Terragrunt off OpenTofu, which has no `oci` backend.

Ansible needs one more, because the dynamic inventory queries a compartment:

```sh
export OCI_COMPARTMENT_OCID=ocid1.tenancy.oc1..xxx
```

## Deploy

### 1. State bucket, once

```sh
source keys/.env
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap apply
```

Copy `objectstorage_namespace` and `state_bucket` from the outputs into
`infra/live/prod/env.hcl` and `infra/live/rc/env.hcl`.

### 2. Infrastructure

```sh
source keys/.env
cd infra/live/prod

terragrunt run --all plan
terragrunt run --all apply
```

Terragrunt walks the dependency graph on its own: peering and network first,
then identity and platform, then database, then app-tier.

`rc` shares the prod network, platform and identity, so prod has to exist first:

```sh
cd infra/live/rc
terragrunt run --all apply
```

### 3. Configuration

`ansible.cfg` already points at `inventory/oci.yml`, so no `-i` is needed.

```sh
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-inventory --graph      # hosts grouped by the pscloud.role tag
ansible-playbook site.yml      # configure every host
ansible-playbook image.yml     # build the application image
ansible-playbook deploy.yml -e canary_action=up
```

## Everyday commands

```sh
cd infra/live/prod/network
terragrunt plan                     # one unit
terragrunt apply
terragrunt output                   # subnet_ids, nsg_ids, ...
terragrunt destroy                  # only this unit's state

cd infra/live
terragrunt dag graph                # dependency graph
terragrunt hcl validate             # parse every unit, no cloud calls
terragrunt hcl fmt

terraform fmt -recursive infra/modules
```

Rebuilding the application image:

```sh
cd packer
packer build -var compartment_ocid=$OCI_COMPARTMENT_OCID app.pkr.hcl
export PSCLOUD_APP_IMAGE_ID=ocid1.image.oc1...    # read by the app-tier unit
```

## Changing things

- Sizing, CIDRs, ports, tags: `infra/live/<env>/env.hcl`
- What a unit passes to its module: `infra/live/<env>/<unit>/terragrunt.hcl`
- Resource shape: `infra/modules/<module>`

Modules take no environment-specific defaults — everything comes in as an
input, so the same module serves prod and rc.
