# 03 — Monitoramento

Uma máquina ARM (`pscloud-monitoring-01`, 1 OCPU, 8 GB, disco de dados de 50 GB
em `/mnt/monitoring-data`) com Docker, em `/opt/observability`:

| Serviço | Porta | Memória (limite / cache) | Para quê |
|---|---|---|---|
| VictoriaMetrics | 8428 | 2512 MB / 1500 MB | métricas (retenção 7 dias) |
| VictoriaLogs | 9428 | 2 GB / 1200 MB | logs (retenção 7 dias) |
| vmalert | 8880 (local) | 256 MB | avalia as regras de alerta |
| Alertmanager | 9093 (local) | 192 MB | envia os alertas |
| Grafana | 3000 (público) | 768 MB | dashboards e busca de logs |
| mysqld_exporter | 9104 (local) | — | métricas do MySQL |

Os containers somam 5.776 MB, dentro do budget de 6.144 MB
(`monitoring_mem_budget_mb`); o resto dos 8 GB fica para o sistema, Fluent Bit e
o Ansible. O "cache" é o `memory.allowedBytes` de cada um, mantido em ~60% do
limite. O `monitoring.yml` recusa rodar se a soma passar do budget ou se um
cache passar de 70% do limite.

## Como os dados chegam

Cada máquina roda **Fluent Bit**, que coleta e empurra para o monitoring:

- métricas do host (CPU, memória, disco, rede, systemd) e por app (cgroup:
  memória, swap, CPU, pressão);
- conexões e requisições do nginx (`nginx_up`, `nginx_connections_*`,
  `nginx_http_requests_total`), do nginx-prometheus-exporter em
  `127.0.0.1:9113` de cada máquina de app;
- requisições do nginx viram métricas (`log_metric_counter_nginx_requests`,
  `log_metric_histogram_nginx_request_duration_seconds`);
- logs: stdout das apps (`job=app`), nginx (`job=nginx`), erros do host
  (`job=host`), containers do monitoring (`job=monitoring`).

As portas 8428/9428 só aceitam tráfego das máquinas das apps (NSG).

## Grafana

`http://137.131.157.149:3000`, usuário `admin`, senha no segredo
`pscloud-grafana-admin` ([como ler](07-operacao-dia-2.md#segredos)).

Dashboards provisionados automaticamente (não dá para editar pela tela; altere o
JSON):

| Dashboard | Mostra |
|---|---|
| **PSCloud — Aplicações** | APIs rodando/paradas, req/s, 5xx, latência, memória/CPU por API, reinícios, OOM, logs de falha |
| Node Exporter Full | cada máquina em detalhe |
| MySQL 8.0 Overview | o banco |
| VictoriaMetrics / VictoriaLogs single-node | o próprio monitoramento |

Ficam em `ansible/roles/monitoring_stack/files/observability/grafana-provisioning/dashboards/`.

### Buscar logs (Explore → VictoriaLogs)

```
job:=app unit:="dotnet-app@pixapi.service"           log de uma API
job:=app kind:in(oom,crash,failed)                     falhas de todas
job:=nginx app:=virtualstore status:>=500              erros 5xx no nginx
job:=host "Killed process"                             quem o OOM matou
```

## Alertas

Regras em `ansible/roles/monitoring_stack/files/observability/alerts/`:

| Grupo | Principais |
|---|---|
| host | `HostDown`, `HostOOMKill`, `ServiceDown`, `ServiceRestartedAfterFailure`, memória/CPU/disco/inodes |
| app | 5xx, 400, 404, latência p95, API perto do limite de memória |
| database | `MySQLDown`, conexões recusadas/perto do limite, restart, queries lentas, deadlocks |
| monitoring | disco do VictoriaMetrics, erros de ingestão, falha do vmalert |

Ver o que está disparando: interface do vmalert por túnel
(`ssh -L 8880:127.0.0.1:8880 -i ~/.ssh/pscloud-monitoring ubuntu@137.131.157.149`
e abra `http://localhost:8880`), ou no monitoring
`curl -s 127.0.0.1:8880/api/v1/alerts | jq '.data.alerts[].labels.alertname'`.

> **Pendente:** o `alertmanager.yml` ainda não tem destino (e-mail, Telegram…).
> Até configurar, os alertas só aparecem no vmalert/Grafana.

Limitações: se o próprio monitoring cair, nada alerta (use um monitor de
uptime externo). Para validar uma regra antes de subir:
`vmalert-prod -dryRun -rule='alerts/*/*.yml'`.

## Mudar algo

| Mudança | Arquivo | Aplicar (no monitoring) |
|---|---|---|
| alerta, dashboard, compose | `roles/monitoring_stack/files/observability/` | `ansible-playbook -i inventories/production monitoring.yml --tags stack` |
| coleta do Fluent Bit | `group_vars/role_app/observability.yml`, `group_vars/role_monitoring.yml` | `site.yml --tags agent` / `monitoring.yml --tags agent` |
| memória/retenção do stack | `group_vars/role_monitoring.yml` | `monitoring.yml --tags stack` |
| coletores do MySQL | `group_vars/role_monitoring.yml` (`mysqld_exporter_*`) | `monitoring.yml --tags mysqld_exporter` |
| exporter do nginx | `group_vars/role_app/nginx.yml` (`nginx_exporter_*`) | `site.yml --tags nginx_exporter` |

## Na máquina

```sh
cd /opt/observability
sudo docker compose ps
sudo docker compose logs -f victoriametrics
sudo systemctl status fluent-bit mysqld_exporter
df -h /mnt/monitoring-data
```
