# 01 — Bootstrap

Do zero até a primeira versão no ar. Faça na ordem; cada passo depende do
anterior.

## 1. Credenciais no seu notebook

```sh
cp .env.example keys/.env      # preencha
source keys/.env
oci iam region list > /dev/null && echo ok   # ~/.oci/config funcionando
```

## 2. Bucket de estado (uma vez na vida)

```sh
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap apply
```

Copie `objectstorage_namespace` e `state_bucket` da saída para
`infra/live/prod/env.hcl` e `infra/live/rc/env.hcl`.

## 3. Infraestrutura

```sh
cd infra/live/prod
terragrunt run --all plan
terragrunt run --all apply
```

Cria, nessa ordem: rede → identidade → plataforma (vault, chaves SSH, senha
admin do MySQL, bastion) → banco → monitoring → pool das apps + load balancer.

> O banco tem configurações que só podem ser escolhidas na criação. Leia
> [02 — Banco de dados](02-banco-de-dados.md) **antes** de aplicar `database`.

rc (opcional, usa a rede do prod): `cd infra/live/rc && terragrunt run --all apply`.

## 4. Segredos que só você tem

O Terraform já criou `pscloud-mysql-admin` e as chaves SSH
(`pscloud-ssh-<role>-priv`). Crie à mão os que vêm de fora:

| Segredo | Valor |
|---|---|
| `pscloud-smtp-password` | senha do e-mail `naoresponder@pontosys.com` |
| `pscloud-jwt-monitorclientes` | chave JWT da monitorclientesapi/geradorrelatoriosapi |
| `pscloud-github-token` | PAT *fine-grained* do GitHub, **Contents: read** em `pontosys-cloud` (o monitoring clona o repo com ele) |

```sh
for s in smtp-password jwt-monitorclientes github-token; do
  read -rsp "pscloud-$s: " v; echo
  oci vault secret create-base64 --compartment-id "$OCI_COMPARTMENT_OCID" \
    --vault-id "$OCI_VAULT_OCID" --key-id "$OCI_VAULT_KEY_OCID" \
    --secret-name "pscloud-$s" --secret-content-content "$(printf %s "$v" | base64 -w0)"
done
```

`pscloud-grafana-*`, `pscloud-mysql-exporter` e `pscloud-db-<app>` são gerados
pelo Ansible na primeira execução.

## 5. Bootstrap do monitoring (do notebook, uma vez)

Os inventários `production` e `rc` autenticam por *instance principal*, que só
existe **dentro** da OCI — do notebook eles falham com
`Instance principals authentication can only be used on OCI compute instances`.
Por isso o primeiro passo usa o inventário `bootstrap`: um host fixo
(`MONITORING_IP`) e a sua API key.

```sh
source keys/.env                      # com MONITORING_IP preenchido

oci secrets secret-bundle get-secret-bundle-by-name --vault-id "$OCI_VAULT_OCID" \
  --secret-name pscloud-ssh-monitoring-priv \
  --query 'data."secret-bundle-content".content' --raw-output | base64 -d > ~/.ssh/pscloud-monitoring
chmod 600 ~/.ssh/pscloud-monitoring

cd ansible
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
source .venv/bin/activate
ansible-galaxy install -r requirements.yml

ansible-playbook -i inventories/bootstrap bootstrap.yml
```

O `bootstrap.yml` deixa o monitoring pronto para ser o controlador. Tudo fica
em `/home/ubuntu` (`ansible_manager_home`):

| Arquivo | De onde vem |
|---|---|
| `~/.ssh/pscloud-monitoring`, `~/.ssh/pscloud-app` | vault (`pscloud-ssh-*-priv`) |
| `~/.ssh/config` | `10.20.0.*` usa a chave do monitoring, `10.20.*` a das apps: `ssh 10.20.16.x` direto |
| `~/.git-credentials` | vault (`pscloud-github-token`) |
| `~/pscloud` | clone do repositório, com as collections instaladas |
| `~/.env` | `OCI_*` e `PSCLOUD_APP_IMAGE_ID` do seu `keys/.env`, carregado em todo login (mantido se o `keys/.env` não estiver carregado) |

Ansible e SDK OCI ficam em `/opt/ansible`, com os comandos no PATH. No host não
há chave de API: tudo lá autentica por *instance principal*. Tudo isso é o role
`ansible_manager`.

Pode rodar de novo quando quiser (troca de token, chave, OCID). Se já existir
um `~/pscloud` que não seja um clone git, apague-o antes.

## 6. Monitoring completo (de dentro dele)

```sh
ssh -i ~/.ssh/pscloud-monitoring ubuntu@$MONITORING_IP
cd ~/pscloud/ansible
ansible-playbook -i inventories/production monitoring.yml
```

Sobe Docker, VictoriaMetrics/Logs, Grafana, alertas, exporter do MySQL e
Fluent Bit. Daqui em diante **tudo roda de dentro do monitoring**: a pipeline
faz isso sozinha; à mão, veja [07](07-operacao-dia-2.md#rodar-o-ansible-à-mão).

## 7. Banco e primeira configuração das apps

1. Importar o banco: [02 — Banco de dados](02-banco-de-dados.md).
2. No monitoring, contas das apps e configuração completa do pool:

```sh
cd ~/pscloud/ansible
ansible-playbook -i inventories/production database.yml
ansible-playbook -i inventories/production site.yml -l pool_stable
```

## 8. GitHub

Repositório `pontosys-cloud` — *Settings → Secrets and variables → Actions*:

| Secrets | Variables |
|---|---|
| `OCI_CI_TENANCY_OCID`, `OCI_CI_USER_OCID`, `OCI_CI_FINGERPRINT`, `OCI_CI_PRIVATE_KEY` | `OCI_CI_REGION`, `OCI_VAULT_OCID`, `OCI_COMPARTMENT_OCID`, `OCI_MONITORING_IP` |
| | `OCI_STABLE_POOL_ID`, `OCI_CANARY_POOL_ID`, `OCI_LB_ID`, `OCI_APP_BACKEND_SET_NAME` (canary/promote) |

Crie os environments `rc`, `canary` e `stable` (pode exigir aprovação no `stable`).

Repositórios das apps: os mesmos 4 secrets `OCI_CI_*`, a variável
`OCI_CI_REGION` e o secret `INFRA_REPO_TOKEN` (PAT *fine-grained* com
*Contents: write* em `pontosys-cloud`). As pipelines ficam em
`.github/workflows/deploy-*.yml` de cada repo de app.

O usuário OCI do CI precisa ler segredos do vault, gravar no bucket
`pscloud-releases` e (para canary/promote) gerenciar instance pools.

## 9. Primeiro deploy

Preencha `ansible/group_vars/role_app/versions_stable.yml` com as versões e dê
push em `main`. O workflow `deploy` aplica sozinho. Detalhes em
[05](05-deploy-e-pipelines.md).

Teste: `curl -s -o /dev/null -w '%{http_code}\n' http://144.22.172.90/readyz`
deve dar qualquer coisa **menos 502**.
