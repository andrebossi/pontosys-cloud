# Prerequisites

What has to exist before `site.yml` does anything useful, and who creates it.

Everything named here lives in **one OCI Vault per environment**. The vault
itself and its KMS key come from `infra/live/<env>/platform`; Ansible reads
`oci_vault_id` and `oci_vault_key_id` from the environment (see
[keys/.env.example](../keys/.env.example)).

## Naming

Every secret is `<prefix>-<kind>[-<name>]`, where the prefix is `label_prefix`
from `infra/live/<env>/env.hcl` — **`pscloud`** today. There is no environment
segment in the name: `label_prefix` is already per-environment, and so is the
vault.

Ansible builds the same names from `secret_prefix` in
[group_vars/all.yml](group_vars/all.yml). If you rename the prefix on one side,
rename it on the other or nothing resolves.

## Who creates what

| Secret | Created by | When |
|---|---|---|
| `pscloud-mysql-admin` | Terraform (`platform`) | with the DB system |
| `pscloud-ssh-app`, `pscloud-ssh-db` | Terraform (`platform`) | with the instances |
| `pscloud-db-<app>` | **Ansible** (`database.yml`) | first run, per application |
| `pscloud-smtp-password` | **you, by hand** | before the first `site.yml` |
| `pscloud-jwt-monitorclientes` | **you, by hand** | before the first `site.yml` |

The split is not arbitrary. Terraform creates what it can reach and what must
exist before anything else does. The MySQL DB System is **private and
unreachable from where Terraform runs**, so Terraform cannot create a database
account — it could write a password to the vault and hope an account matching
it appeared. Ansible runs inside the VCN, so it mints the password, stores it,
and creates the account in the same run; there is never a moment where the two
disagree.

The last two are values that come from **outside** the fleet. Nothing can
generate them, so nothing tries.

## Must exist before the first run

### 1. `pscloud-mysql-admin` — Terraform

A JSON document. Created by `infra/modules/platform` alongside the DB system.

```json
{ "username": "pscloudadm", "password": "...",
  "host": "pscloudmysql.db.vcn.oraclevcn.com", "port": 3306 }
```

This is the seed for everything else: `database.yml` connects as this account
to create the others, and takes the **host and port** from it, so where the
database lives is never written down twice.

### 2. `pscloud-smtp-password` — by hand

The KingHost SMTP password for `naoresponder@pontosys.com`. Read by
`virtualstore` as `SmtpClientData__MailPass`.

```sh
oci vault secret create-base64 \
  --compartment-id "$OCI_COMPARTMENT_OCID" \
  --vault-id "$OCI_VAULT_OCID" \
  --key-id "$OCI_VAULT_KEY_OCID" \
  --secret-name pscloud-smtp-password \
  --secret-content-content "$(printf %s 'THE-PASSWORD' | base64 -w0)"
```

### 3. `pscloud-jwt-monitorclientes` — by hand

The JWT signing key shared by `monitorclientesapi` and
`geradorrelatoriosapi` — both read it as `TokenConfigurations__Key`. **They
must hold the same value**: one signs the token the other validates.

```sh
oci vault secret create-base64 \
  --compartment-id "$OCI_COMPARTMENT_OCID" \
  --vault-id "$OCI_VAULT_OCID" \
  --key-id "$OCI_VAULT_KEY_OCID" \
  --secret-name pscloud-jwt-monitorclientes \
  --secret-content-content "$(printf %s 'THE-KEY' | base64 -w0)"
```

> The old machine's `appsettings.json` files, under
> [files/nginx/nginx-config/](files/nginx/nginx-config/), hold the values these
> replace — **and are in git history**. Treat them as compromised: put new
> values in the vault rather than the ones you find there.

Which references exist is not a list to maintain by hand: it comes from
`app_secret_refs` in
[group_vars/role_app/config.yml](group_vars/role_app/config.yml). Adding an
entry there adds a name Ansible will expect to find.

## Created by Ansible on the first run

`database.yml` mints one credential per application that declares
`connections` in the catalog — five today:

```
pscloud-db-virtualstore          pscloud-db-cadastrosapi
pscloud-db-monitorclientesapi    pscloud-db-entradaapi
pscloud-db-geradorrelatoriosapi
```

Each is a JSON document with the whole DSN, so an application needs nothing
else to build a connection string:

```json
{ "host": "...", "port": 3306, "database": "virtualstoreglobal",
  "username": "virtualstore_app", "password": "...",
  "grants": ["SELECT","INSERT","UPDATE","DELETE"], "host_acl": "10.20.%" }
```

Adding an application to the catalog with a `connections` map is all it takes;
the next `database.yml` mints its credential and creates its MySQL account.

**Existing credentials are never overwritten.** A run reads first and only
mints what is absent, so it is safe to re-run. Rotation is explicit:

```sh
ansible-playbook database.yml -e db_rotate=true
ansible-playbook site.yml --tags apps          # straight after
```

The first adds a new **version** to each secret and moves MySQL onto it; the
second rewrites the env files and restarts the applications whose file changed.
Between them the applications still hold the previous password — the vault
keeps both versions — so run them back to back.

## Migrating from the Terraform-owned credentials

`infra/modules/platform` used to create the five `pscloud-db-*` secrets. It no
longer does — so the next `terragrunt apply` on the platform unit would see
them in state, find no resource for them, and **schedule them for deletion**.

Tell Terraform to forget them instead, before applying:

```sh
cd infra/live/prod/platform
for a in virtualstore monitorclientesapi geradorrelatoriosapi cadastrosapi entradaapi; do
  terragrunt state rm "oci_vault_secret.app_db[\"$a\"]"
  terragrunt state rm "random_password.app_db[\"$a\"]"
done
terragrunt plan          # no destroy of any -db- secret
```

Ansible then adopts them: `database.yml` reads first and only mints what is
absent, so the existing credentials and the MySQL accounts behind them are
untouched. **Passwords do not change and nothing restarts.**

Letting Terraform delete them instead also recovers — Ansible would mint new
ones on the next `database.yml` — but that is a rotation, so the applications
would serve with stale passwords until `site.yml --tags apps` follows.

The same applies to the backup bucket, which the platform module no longer
creates. Decide deliberately: `terragrunt state rm oci_objectstorage_bucket.backups`
keeps the bucket and its contents, applying without it deletes them.

## Not secrets, but also prerequisites

| | |
|---|---|
| `pscloud-releases` bucket | `infra/bootstrap`. Artifacts live at `artifacts/<name>/<name>-<version>.tar.gz` |
| Artifacts uploaded | one per application in the catalog, plus `webroot` |
| `OCI_VAULT_OCID`, `OCI_VAULT_KEY_OCID`, `OCI_COMPARTMENT_OCID` | in `keys/.env`, sourced |
| `oci` SDK on the controller | `pip install -r requirements.txt` |

## Checking before you run

```sh
source keys/.env

# every name the fleet will ask for, and whether it is there
for s in mysql-admin smtp-password jwt-monitorclientes \
         db-virtualstore db-monitorclientesapi db-geradorrelatoriosapi \
         db-cadastrosapi db-entradaapi; do
  printf '%-34s ' "pscloud-$s"
  oci secrets secret-bundle get-secret-bundle-by-name \
    --secret-name "pscloud-$s" --vault-id "$OCI_VAULT_OCID" \
    --query 'data."version-number"' --raw-output 2>/dev/null \
    && echo || echo MISSING
done
```

`db-*` reading MISSING before the first `database.yml` is expected. Anything
else missing will stop `site.yml` at the secret read, with the name in the
message.
