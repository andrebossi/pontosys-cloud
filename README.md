# pscloud

Infraestrutura da Virtual Store na OCI (`sa-saopaulo-1`): Terragrunt/Terraform
para a nuvem, Ansible para as máquinas, GitHub Actions para o deploy.

Arquitetura: [ARCHITECTURE.md](ARCHITECTURE.md).

## Procedimentos

| | |
|---|---|
| [01 — Bootstrap](docs/01-bootstrap.md) | do zero até o primeiro deploy |
| [02 — Banco de dados](docs/02-banco-de-dados.md) | criar, importar o dump, contas |
| [03 — Monitoramento](docs/03-monitoramento.md) | Grafana, dashboards, alertas, logs |
| [04 — Aplicações](docs/04-aplicacoes.md) | catálogo, configs, segredos, arquivos no host |
| [05 — Deploy e pipelines](docs/05-deploy-e-pipelines.md) | rc, canary, stable, rollback |
| [06 — Autoscaling](docs/06-autoscaling.md) | pool, health check, imagem |
| [07 — Operação (dia 2)](docs/07-operacao-dia-2.md) | acessos, debug, logs, segredos, incidentes |

## Onde estão as coisas

| O quê | Onde |
|---|---|
| Site (load balancer) | `http://144.22.172.90` |
| Monitoring + Grafana | `137.131.157.149` (privado `10.20.0.190`), Grafana na porta `3000` |
| Máquinas das apps | pool `pscloud-pool-stable`, rede privada `10.20.16.0/20` |
| Banco | MySQL HeatWave `pscloudmysql.db.vcn.oraclevcn.com:3306` |
| Segredos | OCI Vault `pscloud-vault`, segredos `pscloud-*` |
| Artefatos das apps | bucket `pscloud-releases`, `artifacts/<app>/<app>-<versão>.tar.gz` |
| Estado do Terraform | bucket `pscloud-tfstate` |
| Versões em cada ambiente | `ansible/group_vars/role_app/versions_{rc,canary,stable}.yml` |
| Apps (portas, limites, banco) | `ansible/group_vars/role_app/applications.yml` |

## Repositório

```
infra/bootstrap     bucket de estado (aplicado uma vez, estado local)
infra/modules       módulos Terraform genéricos
infra/live/prod     rede, identidade, plataforma, banco, monitoring, app-tier
infra/live/rc       máquinas e LB do rc, sobre a rede do prod
ansible/            playbooks, roles, inventários (production, rc, local)
.github/            workflows: deploy, promote, canary, rc, image
resources/          Packer (imagem das apps) e Vagrant (ambiente local)
scripts/package.sh  empacota o servidor antigo em artefatos
docs/               procedimentos operacionais
```

## Ferramentas

| | versão |
|---|---|
| Terraform | 1.15+ (o backend `oci` não existe no OpenTofu) |
| Terragrunt | 1.1+, com `TG_TF_PATH=terraform` |
| OCI CLI | com `~/.oci/config` |
| Python | 3.12+ (Ansible fica num venv em `ansible/.venv`) |
