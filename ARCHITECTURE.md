# Arquitetura

OCI `sa-saopaulo-1`, uma VCN `10.20.0.0/16`. O `prod` cria rede, identidade,
plataforma, banco, monitoring e o pool das apps; o `rc` só adiciona máquinas e
um load balancer próprio em cima disso.

```
                         Internet
            ┌───────────────┼─────────────────┐
     ┌──────▼─────┐  ┌──────▼──────┐   ┌──────▼──────┐
     │  LB prod   │  │  LB rc      │   │ monitoring  │  Grafana :3000, SSH :22
     │ :80        │  │ :80         │   │ ARM, 8 GB   │  controlador do Ansible
     └──────┬─────┘  └──────┬──────┘   └──────┬──────┘
  public 10.20.0.0/24 ──────┼─────────────────┼──────────── rota: internet gateway
     ┌──────▼─────────┐ ┌───▼──────────┐      │ métricas/logs (8428/9428)
     │ pool stable    │ │ máquinas rc  │◄─────┘ SSH do Ansible
     │ 1..2, autoscale│ │ fixas        │
     │ pool canary 0  │ └───┬──────────┘
     └──────┬─────────┘     │
  app 10.20.16.0/20 ────────┼──────────────────────────── rota: NAT + service gateway
            │ 3306          │
     ┌──────▼───────────────▼┐
     │ MySQL HeatWave        │  + NLB público :55336 (clientes externos)
     └───────────────────────┘
  db 10.20.32.0/24 ────────────────────────────────────── rota: só service gateway
```

## Unidades (Terragrunt)

| prod | | rc |
|---|---|---|
| `network` | VCN, subnets, gateways, NSGs | usa a do prod |
| `identity` | tags `pscloud.*`, dynamic groups, policies | usa a do prod |
| `platform` | vault, chave KMS, chaves SSH, senha admin do MySQL, bastion | usa a do prod |
| `database` | MySQL + NLB | usa o do prod |
| `monitoring` | máquina de monitoramento | usa a do prod |
| `app-tier` | LB, instance configuration, pools stable/canary, autoscaling | `compute` + `loadbalancer` |

Um estado por unidade no bucket `pscloud-tfstate`; aplicar uma não toca nas
outras. Módulos em `infra/modules` não têm valores de ambiente.

## Rede

- Uma route table por subnet: a do banco não tem rota default.
- NSGs (`lb`, `app`, `db`, `monitoring`) com regras entre grupos, não por IP:
  uma máquina criada pelo autoscaling já nasce com as permissões.
- Entradas permitidas: LB 80/443 ← internet; app 80 ← LB; app 22 ← monitoring;
  db 3306 ← app, monitoring e clientes externos; monitoring 8428/9428 ← app;
  monitoring 22/3000 ← internet.

## Identidade e segredos

A tag definida `pscloud.role` (`app`, `monitoring`) decide três coisas: o
dynamic group (e com ele as permissões da máquina), o grupo no inventário do
Ansible e quais segredos a máquina lê. `pscloud.environment` separa prod de rc.

Segredos só no OCI Vault. O Terraform gera o que existe antes de tudo (chaves
SSH, admin do MySQL); o Ansible gera o resto (contas das apps, Grafana) e
escreve nas máquinas só o necessário, em `/etc/dotnet-apps/<app>.env`.

## Máquinas

- **Apps**: `VM.Standard.E4.Flex` (x86), 1 OCPU, 6 GB. Nginx na porta 80, cada
  API em `127.0.0.1:500x`, limites por API via systemd. Detalhes em
  [docs/04](docs/04-aplicacoes.md).
- **Monitoring**: `VM.Standard.A1.Flex` (ARM), 1 OCPU, 8 GB, IP público.
  VictoriaMetrics, VictoriaLogs, vmalert, Alertmanager e Grafana em Docker.
  Também é de onde as pipelines rodam o Ansible.
- **Banco**: MySQL HeatWave `MySQL.2`, 50 GB, backup diário com PITR.

## Pendências conhecidas

- Load balancer só em HTTP; HTTPS aparece ao definir `lb_certificate`.
- NLB do banco escuta em 55336, mas o NSG `db` libera só 3306 para fora.
- Máquina nova do pool não se configura sozinha ([docs/06](docs/06-autoscaling.md)).
- Alertmanager sem destino ([docs/03](docs/03-monitoramento.md#alertas)).
- Módulo `peering` existe, mas não está aplicado.
