# Arquitetura de referência — OCI São Paulo

## O que este repositório monta

```
                          Internet
                              │
                    ┌─────────┴─────────┐
                    │                   │
              ┌─────▼─────┐       ┌─────▼──────┐
              │ Flexible  │       │ IP público │
              │ LB 10Mbps │       │ (só 22/443 │
              │ HA nativo │       │  de admin) │
              └─────┬─────┘       └─────┬──────┘
   sn-public-lb     │      sn-public-mgmt│
   10.20.0.0/24     │      10.20.1.0/24  │
  ─────────────────┼────────────────────┼──────────────────
                    │                    │  pscloud-mon-01
        ┌───────────┴────────┐           │  A1.Flex 2/8  FD-1
        │   Instance Pool    │           │  Prometheus · Loki
        │  FD-1        FD-2  │           │  Grafana · Alertmanager
        │  ┌────┐    ┌────┐  │           │
        │  │app │    │app │  │◄──push────┤ (remote_write 9090
        │  └──┬─┘    └─┬──┘  │           │  Loki 3100)
        └─────┼────────┼─────┘           │
   sn-private-app  10.20.16.0/20 (4094 IPs)
  ─────────────┼────────┼────────────────┼──────────────────
               └────┬───┘                │
                    │ 3306               │ 3306 + 22
              ┌─────▼──────────────┐     │
              │  pscloud-db-01     │◄────┘
              │  A1.Flex 2/6 FD-3  │
              │  boot 50G · dados  │
              │  150G VPU20        │
              └─────┬──────────────┘
   sn-private-db    │ 10.20.32.0/24
  ──────────────────┼───────────────────────────────────────
                    │ Service Gateway (não passa pela internet)
              ┌─────▼──────────────┐
              │ Object Storage     │  full diário · dump semanal
              │ backups (versionado│  binlog a cada 15 min
              │  + lifecycle)      │
              └────────────────────┘

   Reservado: 10.20.48.0/20 e 10.20.64.0/18 — expansão sem re-endereçar
```

## Decisões e o porquê

### São Paulo tem UMA availability domain

`sa-saopaulo-1` é região de AD única. Isso decide o resto do desenho: **toda a
tolerância a falha é por fault domain**, e não por AD. O instance pool lista as
três FDs e distribui em round-robin; o banco fica fixo na FD-3, que é a que o
pool de 2 instâncias não ocupa. Nenhuma falha de rack derruba aplicação e banco
juntos.

Se o requisito for sobreviver à perda da região inteira, FD não resolve — aí
entra réplica em `sa-vinhedo-1` com DRG, e o custo dobra.

### Por que NSG e não security list

Toda regra de rede é NSG, e a security list default fica vazia
(`lockdown_default_seclist = true`). O ganho é a referência NSG→NSG: a regra diz
"o NSG de app fala com o NSG de banco na 3306", não "10.20.16.0/20 fala com
10.20.32.0/24". Uma instância nova do pool herda a permissão no instante em que
entra no NSG — sem editar rede, sem CIDR para manter.

É isso que atende ao "flexível para adicionar mais aplicações depois": adicionar
aplicação **não toca em rede**. Elas compartilham a VM, o NSG e o nginx; o que
muda é uma entrada em `applications` no `env.hcl`.

### O banco só é alcançável de dentro

Duas regras de ingress no `nsg-db`, ambas NSG→NSG: uma do `nsg-app`, outra do
`nsg-monitoring`. Não existe regra por CIDR, não existe `0.0.0.0/0`, e a subnet
é privada (`prohibit_public_ip_on_vnic`). O caminho de saída para o bucket de
backup é o **Service Gateway** — o dump não passa pela internet.

### Health check tira tráfego, não instância

São duas camadas diferentes, e confundi-las custa caro:

- **Health check do LB** (`/healthz`) — o balanceador para de mandar requisição
  para o backend que reprovar 3 vezes. A instância continua no pool.
- **Instance pool** — recria instância que o hipervisor reporta como parada.

O `/healthz` responde 200 **sem tocar no banco**, de propósito. Se dependesse do
MariaDB, uma queda do banco reprovaria as duas instâncias ao mesmo tempo, o LB
tiraria todo mundo de rotação e o cliente veria 502 do balanceador em vez da
página de erro da aplicação. Saúde de dependência é `/readyz`, consumido pelo
alerta — não pelo LB.

### Convergência no boot não é opcional num instance pool

Instância criada por scale-out (ou pelo próprio pool ao repor uma morta) nasce
com a imagem crua do Ubuntu. Sem convergência automática ela reprova no health
check e o pool "cresceu" sem ganhar capacidade — falha silenciosa.

Duas saídas, ambas implementadas como opção:
- `ansible_pull.repo` no cloud-init (o que está ligado por padrão quando você
  preenche a variável);
- imagem dourada com Packer referenciada no instance configuration.

Não ter nenhuma das duas não é uma opção.

### Chave SSH gerada pelo Terraform — e o preço disso

`tls_private_key` grava a chave privada **em texto claro no state**. Não existe
como gerar chave no Terraform sem isso. As mitigações aplicadas:

1. state em bucket privado, versionado e cifrado com chave do Vault;
2. a privada também vai para o Vault, que é a fonte de verdade para o Ansible —
   ninguém precisa ler o state para operar;
3. um par por papel (`app`, `db`, `monitoring`): comprometer a VM de aplicação
   não entrega o banco.

Se o requisito for "a privada nunca existe fora do HSM", o caminho é OCI Bastion
com sessão gerenciada e chave efêmera do operador — não chave no Terraform.

### Segredos: quem gera é o Terraform, quem aplica é o Ansible

O Terraform gera `random_password` por aplicação e grava um DSN em JSON no OCI
Vault. O Ansible lê pelo **instance principal** (dynamic group casando com a tag
definida `pscloud.role`) e aplica `CREATE USER` + `GRANT` por schema. Nenhuma
senha em playbook, em inventário ou em git.

Girar a senha de uma aplicação = `terraform apply -replace` no `random_password`
+ rodar o playbook. O `update_password: always` no `mysql_user` é o que faz a
rotação realmente chegar no banco.

A tag `pscloud.role` é **uma fonte de verdade para três coisas**: placement e
NSG (Terraform), permissão IAM (dynamic group) e agrupamento do inventário
dinâmico (Ansible).

### Estado separado por stack

Sete `tfstate` independentes, com dependências explícitas:

```
10-network → 15-identity → 20-security → 30-storage
                                ↓
                    40-database · 50-monitoring · 60-apps
```

O motivo prático: um `apply` na camada de aplicação nunca coloca a rede ou o
banco no plano. Não existe o cenário "errei um input e o Terraform propôs
destruir a VCN".

## Três armadilhas do Terragrunt que este repositório já resolve

Todas descobertas na validação, não no `apply`:

1. **`terraform_binary = "terraform"`** — o backend nativo `oci` (lock via
   `If-None-Match`, sem tabela auxiliar) existe no Terraform e **não** no
   OpenTofu. Com os dois no PATH, o Terragrunt chama `tofu` e o init falha com
   *Unsupported backend type*.

2. **O `provider.tf` gerado não pode declarar `required_providers`** — cada
   módulo já declara o seu em `versions.tf`, e o Terraform recusa dois blocos no
   mesmo módulo.

3. **`configuration_aliases` é ilegal em root module** — e o Terragrunt usa cada
   módulo *como* root. Por isso tag namespace, dynamic group e policy vivem em
   `modules/identity`, e o stack `15-identity` muda a região do provider via
   `unit.hcl` (sobrescrever o `generate "provider"` direto no stack não
   funciona: o Terragrunt recusa dois `generate` com o mesmo nome).

## Módulos oficiais da Oracle: o que dá para usar hoje

O pedido era usar `oracle-terraform-modules`. Levantei a organização inteira
antes de escrever. O resultado é desigual e vale registrar, porque a decisão
não é de gosto:

| Módulo | Última publicação | Uso aqui |
|---|---|---|
| `terraform-oci-vcn` **4.0.0** | ativo | **em uso** — VCN, IGW, NAT, Service Gateway, route tables e subnets |
| `terraform-oci-compute-instance` | 2022‑11‑29 | descartado |
| `terraform-oci-tdf-compute-instance` | 2020‑01‑30 | descartado |
| `terraform-oci-tdf-lb` | 2020‑01‑29 | descartado |
| `terraform-oci-tdf-block-storage` | 2020‑02‑04 | descartado |

O módulo oficial de compute não expõe **`fault_domain`** nem **`vpus_per_gb`**.
Adotá‑lo custaria exatamente os dois requisitos que sustentam este desenho:

- sem `fault_domain`, o banco não fica isolado das VMs de aplicação — e numa
  região de AD única a fault domain é a **única** dimensão de isolamento;
- sem `vpus_per_gb`, o volume de dados fica preso em VPU 10 (Balanced, 60
  IOPS/GB), e o "disco de alta performance" pedido para o banco vira Balanced
  silenciosamente.

A família TDF é de janeiro/fevereiro de 2020 — anterior a shapes flexíveis, ao
load balancer flexível e aos níveis de VPU. Não é uma opção.

Onde há módulo oficial mantido, ele é usado. Onde não há, os módulos locais em
`infra/modules/` são finos e declarativos, e o `README` de cada um diz o que
seria substituído se a Oracle voltar a publicar.

## Taxonomia de tags

Sete chaves num namespace de **tags definidas** (`pscloud.*`), não freeform:

| Chave | Valores | Para que serve |
|---|---|---|
| `role` | app · db · monitoring | dynamic group de IAM + inventário do Ansible |
| `tier` | web · data · ops | agrupamento em custo e em inventário |
| `environment` | prod · staging · dev | **rastreada em custo** |
| `data_classification` | public · internal · confidential · restricted | o que responde "onde está o dado sensível" |
| `backup` | none · bronze · silver · gold | política esperada — auditável contra o que existe |
| `cost_center` | texto livre | **rastreada em custo** |
| `owner` | texto livre | quem acorda às 3h |

Tag definida em vez de freeform por dois motivos concretos:

1. regra de dynamic group **só enxerga tag definida** — `tag.pscloud.role.value`
   funciona, freeform não;
2. tag definida aceita **validador de valores**. Com a lista de valores
   permitidos, um `apply` com `role = "database"` (em vez de `"db"`) falha no
   plano. Com freeform tag ele aplicaria, a VM subiria fora de todo dynamic
   group, o instance principal não leria segredo nenhum, e o erro apareceria
   três camadas adiante como *"o Ansible não consegue autenticar no Vault"*.

As tags do banco vão também para o **volume de dados** — é ele que carrega o
dado confidencial e é ele que sobrevive à destruição da VM.

## Variáveis do Ansible: três camadas que se somam

```
group_vars/all.yml              toda VM
group_vars/role_app.yml         ─┐
group_vars/role_db.yml           ├─ o papel (grupo do inventário dinâmico)
group_vars/role_monitoring.yml  ─┘
host_vars/<ip privado>.yml      uma máquina
```

Os grupos `role_*` são criados pelo inventário dinâmico a partir da tag
`pscloud.role` — a mesma tag que o Terraform aplica e que os dynamic groups de
IAM consomem.

O `observability-backend/` do repositório roda **na VM de monitoração**, e só
nela: `group_vars/role_monitoring.yml` aponta `observability_src` para o
diretório versionado e define retenções que cabem no boot volume de 100 GB.
Essa VM manda a própria telemetria para `127.0.0.1` — não faz sentido depender
da rede que se quer observar.

## Fluent Bit dirigido por dados

O `fluent-bit.yaml` é **gerado** a partir de três listas que se somam:

```
fluentbit_inputs_common   (all.yml)        toda VM
+ fluentbit_inputs_role   (role_*.yml)     o papel
+ fluentbit_inputs_host   (host_vars/*)    a máquina
```

Acrescentar uma coleta é acrescentar um dicionário numa dessas listas. Nenhuma
task muda, nenhum template muda.

**Por que a soma é explícita:** o Ansible *substitui* listas de mesmo nome entre
grupos, não concatena. Com um único `fluentbit_inputs`, o `role_db.yml` apagaria
tudo que veio de `all.yml` — e a perda seria silenciosa.

Descartei o mecanismo `includes:` do próprio Fluent Bit (um `conf.d/` de
fragmentos): ele não suporta glob, e a documentação **não especifica** se as
listas `pipeline.inputs` de vários arquivos incluídos são concatenadas ou
sobrescritas. Montar um arquivo único a partir de variáveis não depende de
comportamento não documentado e é trivialmente idempotente.

Três detalhes que fazem a diferença entre "roda" e "roda em produção":

- `validate: fluent-bit --dry-run -c %s` no template — config inválida **não
  chega no disco**, então o agente continua com a última versão boa em vez de
  entrar em restart loop;
- uma task de **poda** remove auxiliares que não estão mais declarados. Sem ela
  o playbook seria idempotente só no que adiciona: tirar um input das variáveis
  deixaria o arquivo antigo em disco e a coleta continuaria de pé;
- verificação final em `http://127.0.0.1:2020/api/v1/health`. `systemctl
  is-active` só diz que o processo subiu.

### O que vem embutido, e o que precisou de ponte

Tudo abaixo é coletor **nativo** do Fluent Bit — nenhum exporter instalado,
nenhuma porta aberta, nenhum serviço extra para vigiar:

| Coletor | Entrega |
|---|---|
| `node_exporter_metrics` | cpu, cpufreq, meminfo, diskstats, filesystem, netdev, loadavg, vmstat, stat, uname, processes, systemd, textfile |
| `fluentbit_metrics` | o próprio agente — sem isto, um agente em backpressure some do gráfico junto com o que deixou de enviar |
| `systemd` | journal, com filtro por unit/slice conforme o papel |
| `nginx_metrics` | stub_status, sem nginx-exporter |
| `prometheus_scrape` | endpoints do stack na VM de monitoração, sem cAdvisor |

Duas lacunas reais, resolvidas pelo collector `textfile` em vez de mais um
processo:

- **CPU/memória por cgroup** (`cgroup-textfile-exporter.sh`, VMs de aplicação) —
  o collector `processes` só conta processos por estado; não dá CPU nem memória
  individual. É este script que produz `app_cpu_throttled_pct` e `app_mem_pct`,
  consumidos pelos alertas de OOM e de throttling.
- **MariaDB** (`mariadb-textfile-exporter.sh`) — lê `SHOW GLOBAL STATUS` pelo
  socket unix (autenticação por `unix_socket`, sem senha em lugar nenhum) e
  publica conexões vs. `max_connections`, estado do thread pool, hit ratio do
  buffer pool, deadlocks, tmp tables em disco. Com banco fora do ar publica
  `mariadb_up 0` — série que some não dispara alerta, ela simplesmente deixa de
  existir no gráfico.

## Diferenças em relação ao diagrama de referência anexado

O diagrama da Oracle que serviu de base mostra **as três subnets públicas** e um
**Autonomous Transaction Processing** como banco. Este desenho diverge nos dois
pontos, seguindo o que foi pedido:

- app e banco em subnet **privada**, com NAT + Service Gateway para saída;
- **MariaDB auto-gerenciado** em VM, com backup próprio para bucket.

O diagrama também mostra autoscaling; aqui ele existe (`autoscaling.enabled`)
mas vem **desligado**, porque o orçamento foi feito para 2 instâncias fixas.

## Ordem de deploy

```bash
# 1. bucket de state (uma vez, state local)
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap apply
# copie os outputs para infra/live/prod/env.hcl

# 2. preencha os CHANGEME de infra/live/prod/env.hcl
#    (tenancy, compartment, namespace, admin_cidrs)

# 3. infraestrutura, na ordem do DAG
cd infra/live/prod
terragrunt run --all plan
terragrunt run --all apply

# 4. configuração
cd ../../../ansible
ansible-galaxy collection install -r requirements.yml
export OCI_COMPARTMENT_OCID=ocid1.compartment...
ansible-playbook site.yml
```

## Pendências conhecidas

- **Ansible não está instalado** neste ambiente; o playbook foi validado por
  parsing de YAML e por renderização Jinja dos templates do Fluent Bit (os três
  papéis geram YAML válido, com as variáveis resolvidas), **não** por execução
  real contra uma VM.
- **Nenhum `terraform apply` foi executado** — não há tenancy configurada aqui
  (`~/.oci` ausente). O que foi verificado: `terraform validate` em todos os
  módulos, `terragrunt hcl validate` na árvore inteira e o DAG de dependências.
- **`VM.Standard.A2.Flex` em São Paulo não foi confirmado.** O `env.hcl` usa
  A1.Flex, que é garantido na região.
- **Certificado TLS do LB** — o listener 443 só sobe quando `lb_certificate` é
  preenchido. Hoje só existe o listener 80.
- **`grafana_admin_password` e `monitoring_fqdn`** ainda não têm valor: defina
  em `host_vars/` (com Ansible Vault) ou por `--extra-vars`. Sem o FQDN o
  Grafana fica acessível só por túnel SSH.
