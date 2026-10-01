# Ansible

Configura as máquinas das apps e o monitoring. Procedimentos (bootstrap, deploy,
operação) estão em [../docs](../docs); aqui fica a referência técnica.

```
site.yml          máquinas das apps, completo (base, runtime, nginx, apps, deploy, agent)
deploy.yml        só troca versões (usado por promote/rc)
database.yml      no monitoring: segredos pscloud-db-* e contas MySQL das apps e do exporter
monitoring.yml    máquina de monitoramento (stack, exporter, agent, ansible_manager)
bootstrap.yml     1ª vez, do notebook: transforma o monitoring em controlador
image.yml         imagem das apps, chamado pelo Packer

group_vars/            igual em todos os ambientes
inventories/production pool stable/canary (inventário dinâmico OCI)
inventories/rc         máquinas do rc
inventories/local      VM Vagrant
inventories/bootstrap  só o monitoring, por IP, com API key (para o bootstrap.yml)
```

## Inventários

Dinâmicos, pelo plugin `oracle.oci`, com autenticação *instance principal*: por
isso rodam **de dentro do monitoring**. A exceção é `inventories/bootstrap`, que
existe para criar esse controlador a partir do notebook. Os hosts são agrupados pelas tags:
`role_app`, `role_monitoring`, `pool_stable`, `pool_canary`. Prod e rc dividem o
compartimento; cada inventário filtra por `pscloud.environment`, então não há
como rodar no ambiente errado.

Sempre passe o diretório: `-i inventories/production` (carrega o
`group_vars` do inventário junto).

## Roles

| Role | Faz |
|---|---|
| `base` | sysctl, journald, firewall (`base_open_ports`), contas `deploy`/`ops` |
| `dotnet_runtime` | .NET 5.0.15 (e 2.1 em x86), OpenSSL 1.1 privado, libgdiplus, fontes |
| `nginx_app` | nginx, rotas por app, `/healthz`, `/readyz`, páginas de erro |
| `dotnet_app` | unit `dotnet-app@`, slice, limites, `appsettings.Production.json`, env files com segredos |
| `app_deploy` | baixa do bucket, troca `current`, health check, rollback |
| `db_users` | segredos `pscloud-db-*`/`pscloud-mysql-exporter` (cria e corrige) e as contas no MySQL; roda no monitoring |
| `observability_agent` | Fluent Bit e o exportador de métricas por app (cgroup) |
| `monitoring_stack` | Docker, VictoriaMetrics/Logs, vmalert, Alertmanager, Grafana |
| `mysqld_exporter` | lê `pscloud-mysql-exporter` do vault e aplica `prometheus.prometheus.mysqld_exporter` no monitoring |
| `ansible_manager` | no monitoring: Ansible + SDK OCI, chaves SSH do vault, `~/.ssh/config`, token do git, clone do repo, collections, `~/.env` |

## Onde muda o quê

| Mudança | Arquivo |
|---|---|
| app nova, porta, banco, segredo | `group_vars/role_app/applications.yml` |
| versão | `group_vars/role_app/versions_<canal>.yml` |
| appsettings | `group_vars/role_app/config.yml` |
| limites por tier, timeouts do nginx | `group_vars/role_app/platform.yml` |
| coleta de logs/métricas | `group_vars/role_app/observability.yml`, `group_vars/role_monitoring.yml` |
| tamanho da máquina | `inventories/<env>/group_vars/all.yml` (`host_vcpus`, `host_memory_mb`) |
| alertas, dashboards | `roles/monitoring_stack/files/observability/` |

## Decisões que não são óbvias

- **OpenSSL 1.1 desempacotado, não instalado.** O .NET 5 precisa de
  `libssl.so.1.1`, que o Ubuntu 24.04 não tem. Fica em `/opt/dotnet/compat/lib`,
  visível só para as apps via `LD_LIBRARY_PATH`.
- **ICU explícito.** O .NET 5 procura ICU até a 67; o host tem 74, então
  `CLR_ICU_VERSION_OVERRIDE` é definido a partir da versão detectada.
- **GC de workstation** (`COMPlus_gcServer=0`): oito processos em 2 vCPUs.
  Prefixo `COMPlus_`, porque `DOTNET_` só vale a partir do .NET 6.
- **Fontes** Arial, Tahoma e `Orator10 BT` (não `Orator`) em
  `/usr/local/share/fonts/msttcore`; sem elas os relatórios saem desalinhados.
- **Sistema de arquivos somente leitura** para as apps (`ProtectSystem=strict`);
  só `shared/` é gravável (e a release inteira, para `pixapi`).
- **`Restart=always` sem limite**: uma app parada porque o banco caiu volta
  sozinha quando ele voltar.
- **Health check do LB não toca no banco**: queda do banco não tira todas as
  máquinas do LB.
- **Contas MySQL com `caching_sha2_password`**; as connection strings levam
  `AllowPublicKeyRetrieval=True` porque não usam TLS.
- **Arquitetura detectada**: apps em x86, monitoring em ARM; runtime, OpenSSL,
  Docker e exporter escolhem o pacote pela `ansible_architecture`.

## Ambiente local

`inventories/local` + `../resources/vagrant`. Autentica no vault com
`~/.oci/config` (`oci_auth_type: api_key`).

`host_vars/` serve para algo verdadeiro em **uma** máquina só (veja
[host_vars/README.md](host_vars/README.md)).
