# 02 — Banco de dados

MySQL HeatWave privado (`pscloudmysql.db.vcn.oraclevcn.com:3306`), shape
`MySQL.2`, 50 GB, backup diário com PITR (7 dias). Quem alcança a porta 3306:
as máquinas das apps e o monitoring.

## Como as apps usam o banco

São dois tipos de conexão:

| | De onde vem | Quem cria |
|---|---|---|
| **Global** (`virtualstoreglobal`, `cep`) | env vars `ConnectionStrings__*` geradas pelo Ansible | `database.yml` (contas `<app>_app`) |
| **Por cliente** (um banco por loja) | tabela `virtualstoreglobal.acessobdvirtualstore`, lida via `monitorclientesapi` | **você**, na importação |

A conexão por cliente é montada no código com `SslMode=none` e sem
`AllowPublicKeyRetrieval`. Isso define as regras abaixo.

## 1. Antes de criar: copiar as configurações do servidor antigo

No servidor antigo:

```sql
SELECT @@version, @@sql_mode, @@lower_case_table_names, @@time_zone,
       @@log_bin_trust_function_creators, @@character_set_server, @@collation_server;
SHOW GRANTS FOR cep_user;
```

O que precisa bater no novo:

| Variável | Por quê |
|---|---|
| `lower_case_table_names` | **só pode ser definida na criação** |
| `sql_mode` | o código usa datas zeradas (`Convert Zero Datetime`) |
| `time_zone` | `NOW()` no SQL; UTC no novo se não ajustar |
| `log_bin_trust_function_creators=ON` | a `virtualstore` cria triggers/procedures em runtime |
| `require_secure_transport=OFF` | as conexões por cliente não usam TLS |

Valores diferentes do padrão da OCI vão numa *MySQL configuration* aplicada ao
DB system (`infra/modules/database`) **antes** do `terragrunt apply`.

## 2. Criar

```sh
cd infra/live/prod/database && terragrunt apply
```

## 3. Importar o dump (manual, a partir do monitoring)

No servidor antigo, um dump por banco (global, cep e cada banco de cliente):

```sh
mysqldump -h <antigo> -P 13306 -u <admin> -p --single-transaction \
  --routines --triggers --events --set-gtid-purged=OFF \
  --databases virtualstoreglobal cep <bancos_dos_clientes...> | gzip > dump.sql.gz
```

Leve o arquivo ao monitoring (`scp dump.sql.gz ubuntu@137.131.157.149:`) e lá:

```sh
sudo apt-get install -y mysql-client
eval "$(oci secrets secret-bundle get-secret-bundle-by-name --auth instance_principal \
  --vault-id "$OCI_VAULT_OCID" --secret-name pscloud-mysql-admin \
  --query 'data."secret-bundle-content".content' --raw-output | base64 -d \
  | jq -r '"DBH=\(.host) DBP=\(.port) DBU=\(.username) MYSQL_PWD=\(.password)"')"
export MYSQL_PWD

zcat dump.sql.gz | mysql -h "$DBH" -P "$DBP" -u "$DBU"
```

> O `oci` CLI não vem instalado no monitoring; o Ansible usa o SDK. Se preferir,
> pegue a senha no seu notebook ([07](07-operacao-dia-2.md#segredos)) e use
> `mysql ... -p`.

Confira que veio a tabela `__EFMigrationsHistory` (a `monitorclientesapi` usa
EF migrations e as contas das apps não têm `CREATE`).

## 4. Acertar o registro de clientes

O dump traz o endereço do servidor antigo. Aponte para o novo:

```sql
SELECT DISTINCT Servidor, Usuario FROM virtualstoreglobal.acessobdvirtualstore;

UPDATE virtualstoreglobal.acessobdvirtualstore
   SET Servidor = 'pscloudmysql.db.vcn.oraclevcn.com'   -- e a porta, se houver coluna: 3306
 WHERE Servidor LIKE '%rds.amazonaws.com%';
```

## 5. Contas dos clientes

Para cada `Usuario`/`Senha` distinto da tabela acima, crie a conta com a
**mesma senha** e acesso total ao banco do cliente (a `virtualstore` faz
`ALTER TABLE`, procedures e triggers nele):

```sql
CREATE USER '<usuario>'@'10.20.%' IDENTIFIED BY '<senha da tabela>';
GRANT ALL PRIVILEGES ON `<banco_do_cliente>`.* TO '<usuario>'@'10.20.%';
```

Como a conexão não usa TLS, teste o pior caso (cache de senha vazio, como
depois de um restart do MySQL):

```sql
FLUSH PRIVILEGES;
```

```sh
mysql -h "$DBH" -u '<usuario>' -p --ssl-mode=DISABLED -e 'select 1'
```

Se der `Authentication requires secure connection`, a conta precisa de outro
plugin de autenticação (`mysql_native_password`, quando a versão permitir).

## 6. Contas das apps e do monitoramento

No monitoring (é ele que roda: está sempre ligado e alcança o 3306):

```sh
cd ~/pscloud/ansible
ansible-playbook -i inventories/production database.yml
```

O role `db_users` faz duas etapas, nesta ordem:

**Segredos** (`tasks/secrets.yml`, só vault, não precisa do banco):

1. Lê `pscloud-mysql-admin`: é a única fonte de host e porta.
2. Lê `pscloud-db-<app>` de cada app com `database:` no catálogo e
   `pscloud-mysql-exporter`.
3. **Corrige** os que apontam errado: grava uma versão nova com host/porta do
   admin e origem `10.20.%` (`10.20.0.%` no exporter). Usuário e senha não
   mudam.
4. Cria os que não existem (senha nova de 32 caracteres).

**Contas** (`tasks/accounts.yml`, precisa do banco):

5. Cria cada conta `<usuário>@'10.20.%'` com `caching_sha2_password`.
6. Permissões: `ALL` (DML e DDL) em cada banco que a app usa, inclusive `cep`
   (lista por app em `applications.yml` → `database.schemas`).
7. Conta `exporter@'10.20.0.%'` com `PROCESS, REPLICATION CLIENT, SELECT`.

Pode rodar quantas vezes quiser: segredo certo não ganha versão nova, conta
existente só é ajustada.

Trocar a senha do exporter (grava versão nova do `pscloud-mysql-exporter`,
altera a conta e reconfigura o `mysqld_exporter` no mesmo run):

```sh
ansible-playbook -i inventories/production database.yml -e db_exporter_rotate=true
```

| Segredo | Usuário |
|---|---|
| `pscloud-db-virtualstore` | `virtualstore_app` |
| `pscloud-db-monitorclientesapi` | `monitorclientes_app` |
| `pscloud-db-geradorrelatoriosapi` | `geradorrelatorios_app` |
| `pscloud-db-cadastrosapi` | `cadastrosapi_app` |
| `pscloud-db-entradaapi` | `entradaapi_app` |
| `pscloud-mysql-exporter` | `exporter` |

Só os segredos, sem banco (para conferir ou corrigir o vault):

```sh
ansible localhost -m include_role -a 'name=db_users tasks_from=secrets.yml' \
  -e @group_vars/all.yml -e @group_vars/role_app/applications.yml
```

No monitoring roda como está; do notebook, acrescente `-e oci_auth_type=api_key`.

## 7. Conferir

- Grafana → **MySQL 8.0 Overview** com dados; alerta `MySQLDown` resolvido.
- `ansible-playbook -i inventories/production site.yml -l pool_stable` sem erro
  na leitura dos segredos.
- Uma tela de cada app funcionando, incluindo uma loja (conexão por cliente).

## Trocar a senha de uma app

```sh
ansible-playbook -i inventories/production database.yml -e db_rotate=true
ansible-playbook -i inventories/production site.yml --tags apps --skip-tags deploy
```

Rode os dois em seguida: entre eles as apps ainda usam a senha anterior. A
senha nova vira uma versão nova do segredo; a anterior continua no vault.
