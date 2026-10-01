# 07 — Operação (dia 2)

## Acessos

```sh
# monitoring (único com IP público)
ssh -i ~/.ssh/pscloud-monitoring ubuntu@137.131.157.149

# máquinas das apps: a partir do monitoring (a chave já está lá)
ssh -i ~/.ssh/pscloud-app ubuntu@10.20.16.x
```

IPs das máquinas das apps, no monitoring:

```sh
ansible-inventory -i ~/pscloud/ansible/inventories/production --graph
```

Sem o IP público, use o Bastion (`terragrunt output bastion_id` em
`infra/live/prod/platform`) com uma sessão de port forwarding para a porta 22.

## Segredos

Todos no vault `pscloud-vault`. Listar:

```sh
oci vault secret list --compartment-id "$OCI_COMPARTMENT_OCID" --all \
  --query 'data[]."secret-name"' --output table
```

Ler um (do notebook, com `keys/.env` carregado):

```sh
segredo() {
  oci secrets secret-bundle get-secret-bundle-by-name --vault-id "$OCI_VAULT_OCID" \
    --secret-name "$1" --query 'data."secret-bundle-content".content' --raw-output | base64 -d
}
segredo pscloud-grafana-admin
segredo pscloud-mysql-admin | jq .
```

| Segredo | Conteúdo | Quem cria |
|---|---|---|
| `pscloud-ssh-{app,monitoring,db}-priv` / `-pub` | chaves SSH | Terraform |
| `pscloud-mysql-admin` | JSON: host, porta, usuário, senha do admin | Terraform |
| `pscloud-db-<app>` | JSON: conexão de cada app | `database.yml` |
| `pscloud-mysql-exporter` | JSON: conta do monitoramento | `database.yml` |
| `pscloud-grafana-admin`, `pscloud-grafana-secret-key` | senha e chave do Grafana | `monitoring.yml` |
| `pscloud-smtp-password` | senha do e-mail `naoresponder@` | à mão |
| `pscloud-jwt-monitorclientes` | chave JWT da monitorclientesapi/geradorrelatoriosapi | à mão |

Trocar um segredo à mão = criar nova versão (`oci vault secret update-base64
--secret-id ... --secret-content-content ...`) e reaplicar a config
([04](04-aplicacoes.md#mudar-uma-configuração)). Senhas do banco:
[02](02-banco-de-dados.md#trocar-a-senha-de-uma-app).

## Rodar o Ansible à mão

No monitoring o login já carrega `~/.env` (OCIDs) e o Ansible. `~/pscloud` é
um clone git: a pipeline faz checkout do commit que está implantando, então
antes de rodar à mão volte para a `main` atualizada (ou para a sua branch):

```sh
cd ~/pscloud && git checkout main && git pull
```

```sh
cd ~/pscloud/ansible
ansible-playbook -i inventories/production site.yml -l pool_stable --check --diff
ansible-playbook -i inventories/production site.yml -l pool_stable
ansible-playbook -i inventories/production monitoring.yml --tags stack
```

Tags úteis: `site.yml` → `base`, `runtime`, `nginx`, `apps`, `deploy`, `agent`;
`monitoring.yml` → `stack`, `agent`, `mysqld_exporter`, `ansible_manager`.

## Uma API com problema

Na máquina da app:

```sh
systemctl status dotnet-app@pixapi
journalctl -u dotnet-app@pixapi -n 200 --no-pager     # exceção de startup aparece aqui
journalctl -u dotnet-app@pixapi -f
systemctl cat dotnet-app@pixapi                       # unit + limites + runtime
sudo systemctl restart dotnet-app@pixapi

curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5008/pixapi   # direto no Kestrel
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/pixapi        # pelo nginx
```

Configuração em uso:

```sh
ls -l /srv/apps/pixapi/current                       # qual versão
sudo cat /srv/apps/pixapi/shared/appsettings.Production.json
sudo cat /etc/dotnet-apps/pixapi.env                 # tem senhas
```

Rodar em primeiro plano, igual ao serviço, para ver a saída inteira (pegue os
`Environment=` de `systemctl cat`):

```sh
sudo systemctl stop dotnet-app@pixapi
sudo systemd-run --pty --uid=dotnetapp --gid=dotnetapp \
  -p EnvironmentFile=/etc/dotnet-apps/pixapi.env \
  -p WorkingDirectory=/srv/apps/pixapi/current \
  -E LD_LIBRARY_PATH=/opt/dotnet/compat/lib -E CLR_ICU_VERSION_OVERRIDE=74 \
  /opt/dotnet/dotnet VirtualStore.Integrations.Pix.Api.dll
sudo systemctl start dotnet-app@pixapi
```

Memória e CPU por app: `systemd-cgtop -m /apps.slice`.

## Logs

| Onde | Como |
|---|---|
| Grafana → Explore → VictoriaLogs | `job:=app unit:="dotnet-app@pixapi.service"` ([mais exemplos](03-monitoramento.md#buscar-logs-explore--victorialogs)) |
| journal da máquina | `journalctl -u dotnet-app@<app>` (7 dias) |
| nginx | `/var/log/nginx/access.json.log`, `/var/log/nginx/error.log` |
| Graylog | `virtualstore`, `dashsapi`, `relatoriosapi`, `cadastrosapi`, `entradaapi` ainda mandam via Serilog |

## Incidentes comuns

| Sintoma | Primeiro passo |
|---|---|
| 502 numa API | `systemctl status dotnet-app@<app>`; se parada, `journalctl -u` |
| `ServiceRestartedAfterFailure` | `journalctl -u dotnet-app@<app>`; se for OOM, Grafana → PSCloud — Aplicações → memória |
| `HostOOMKill` | VictoriaLogs `job:=host "Killed process"` mostra qual processo |
| `HostDown` | `oci compute instance list ...`; máquina do pool morta é recriada pelo pool, depois rode o deploy |
| erro de banco nas lojas | registro `acessobdvirtualstore` e contas dos clientes ([02](02-banco-de-dados.md)) |
| site fora, LB ok | `curl http://144.22.172.90/readyz`; se 502, as APIs não subiram |
| disco do monitoring cheio | `df -h /mnt/monitoring-data`; reduzir `vm_retention`/`vl_retention` |

## Parar e ligar o pool (economia)

```sh
oci compute-management instance-pool stop  --instance-pool-id <id>
oci compute-management instance-pool start --instance-pool-id <id>
```

Ao ligar, as máquinas voltam com a mesma configuração (o disco é mantido).

## Ambiente local

`resources/vagrant` sobe uma VM com o papel de app e de monitoring:

```sh
cd resources/vagrant && vagrant up
cd ../../ansible && ansible-playbook -i inventories/local site.yml
```

Usa seu `~/.oci/config` para ler o vault (`oci_auth_type: api_key`).
