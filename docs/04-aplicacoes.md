# 04 — Aplicações

Oito APIs .NET 5 atrás de um nginx local, mais três sites estáticos. Todas rodam
em todas as máquinas do pool.

| App | Porta | Caminho | Tier | Banco |
|---|---|---|---|---|
| virtualstore | 5000 | `/virtualstore` | site | virtualstoreglobal, cep |
| monitorclientesapi | 5002 | `/monitorclientesapi` | critical | virtualstoreglobal |
| dashsapi | 5003 | `/dashsapi` | api | — |
| relatoriosapi | 5004 | `/relatoriosapi` | batch | — |
| geradorrelatoriosapi | 5005 | `/geradorrelatoriosapi` | batch | virtualstoreglobal |
| cadastrosapi | 5006 | `/cadastrosapi` | api | cep |
| entradaapi | 5007 | `/entradaapi` | api | virtualstoreglobal, cep |
| pixapi | 5008 | `/pixapi` | critical | — |

Sites: `root` (Ionic, em `/`), `app` (Flutter, `/app`), `monitorclientes`
(Flutter, `/monitorclientes`).

As APIs sem banco próprio acessam os bancos **dos clientes** pela
`monitorclientesapi` (veja [02](02-banco-de-dados.md#como-as-apps-usam-o-banco)).

## Os arquivos

Tudo em `ansible/group_vars/role_app/`:

| Arquivo | O que define |
|---|---|
| `applications.yml` | o catálogo: dll, porta, caminho, tier, banco, segredos |
| `config.yml` | `appsettings` não secretos de cada app |
| `platform.yml` | tiers (limites de memória/CPU, timeouts do nginx), runtime |
| `versions_{rc,canary,stable}.yml` | qual versão roda em cada ambiente ([05](05-deploy-e-pipelines.md)) |
| `observability.yml` | coleta de logs/métricas |

Diferenças entre ambientes ficam no inventário:
`ansible/inventories/<production|rc>/group_vars/` (tamanho da máquina, onde
está o monitoring do rc).

### Uma entrada do catálogo

```yaml
virtualstore:
  dll: VirtualStore.Vendas.Service.Api.dll
  port: 5000
  path: /virtualstore
  tier: site
  linked_dirs: [logs]                 # sobrevive entre versões (shared/)
  database:
    secret: db-virtualstore           # segredo pscloud-db-virtualstore
    schemas:
      VSGlobalContext: virtualstoreglobal
      CepContext: cep
  secrets:
    SmtpClientData__MailPass: smtp-password
```

`writable_release: true` (só `pixapi`) deixa a app escrever na própria pasta: ela
grava um `.pem` temporário a cada chamada PIX e o `erro.log`.

## De onde vem cada configuração

Do mais fraco para o mais forte (o de baixo vence):

1. `appsettings.json` do artefato (vem do build; ainda tem dados antigos).
2. `appsettings.Production.json`, gerado de `config.yml`.
3. `/etc/dotnet-apps/<app>.env`: connection strings e segredos, lidos do vault.

`UrlApis` aponta para `127.0.0.1` (a app vizinha na mesma máquina), nunca para
o domínio público.

## Mudar uma configuração

Edite `config.yml` (ou um segredo no vault) e, no monitoring:

```sh
ansible-playbook -i inventories/production site.yml -l pool_stable --tags apps --skip-tags deploy
```

Só reinicia as apps cujo arquivo mudou. Sem `--skip-tags deploy`, ele também
reinstala e reinicia todas.

## Adicionar uma app

1. Entrada nova em `applications.yml` (porta livre, caminho, tier).
2. Bloco em `config.yml` se precisar de `appsettings`.
3. Versão no grupo certo de `versions_*.yml`.
4. Se tiver `database:`, rodar `database.yml` antes.

Unit do systemd, nginx, conta no banco, env file, métricas e logs saem do
catálogo — não precisa mexer em role.

## Na máquina

```
/srv/apps/<app>/releases/<versão>/      o artefato
/srv/apps/<app>/current -> releases/<versão>
/srv/apps/<app>/shared/                 appsettings.Production.json, logs/ ...
/etc/dotnet-apps/<app>.env              segredos (root:dotnetapp 0640)
/etc/systemd/system/dotnet-app@.service unit; limites em dotnet-app@<app>.service.d/
/usr/share/nginx/html/                  sites estáticos
```

Cada API roda como `dotnet-app@<app>.service`, usuário `dotnetapp`, dentro do
`apps.slice`, com o sistema de arquivos somente leitura (exceto `shared/`).
