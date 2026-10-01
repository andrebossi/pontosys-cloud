# 05 — Deploy e pipelines

## Ambientes

| Canal | Arquivo de versões | Máquinas | Como recebe versão |
|---|---|---|---|
| **rc** | `versions_rc.yml` | `infra/live/rc` (inventário `rc`) | tag `vX-rc` ou edição do arquivo |
| **canary** | `versions_canary.yml` | pool `canary` (0 máquinas por padrão) | `promote.yml to=canary` |
| **stable** | `versions_stable.yml` | pool `stable` (produção) | tag `vX`, edição do arquivo ou `promote.yml` |

Os três ficam em `ansible/group_vars/role_app/` e têm o mesmo formato: grupos de
release com a versão de cada app.

```yaml
release_groups_stable:
  pixapi:
    pixapi: "2026.09.12"
  monitorclientes:              # frontend + APIs que sobem juntos
    monitorclientes: "2026.09.12"
    monitorclientesapi: "2026.09.12"
    geradorrelatoriosapi: "2026.09.12"
```

rc e stable usam **o mesmo banco** de produção.

## Como um deploy acontece

```
repo da app (tag)  →  build + upload no bucket  →  commit da versão em pontosys-cloud
                                                     ↓
                                     workflow "deploy" (push em versions_*.yml)
                                                     ↓
                     SSH no monitoring → git checkout do commit → ansible-playbook site.yml
                                                     ↓
                     só as apps cuja versão mudou, uma máquina por vez
```

O workflow `deploy` descobre sozinho quais apps mudaram e em qual canal. Se a
app não responder depois do restart, o Ansible volta a versão anterior naquela
máquina e o job falha.

### Pelo repositório da app

Cada repo de app tem o seu `.github/workflows/deploy-*.yml` (build, upload no
bucket, commit da versão aqui):

- `git tag v1.4.0 && git push --tags` → **stable**
- `git tag v1.4.0-rc && git push --tags` → **rc**

O build falha de propósito se faltar uma pasta de conteúdo que a app precisa
(`Contents`, `Fonts`, `Relatorios`, `Scripts`, `wwwroot`, `ArquivosFiscais`).

### À mão

- Editar a versão em `versions_stable.yml` (ou `_rc`) e dar push em `main`.
- Ou *Actions → deploy → Run workflow*, escolhendo o canal e, se quiser, as apps
  (`["pixapi"]`). Serve também para reaplicar config sem mudar versão.

A versão precisa existir no bucket: `artifacts/<app>/<app>-<versão>.tar.gz`.

## Canary (opcional)

```
canary.yml action=up                 cria 1 máquina no pool canary
promote.yml to=canary group=<grupo>  versão do rc → canary, faz deploy
canary.yml action=traffic weight_percent=10
  ...validar...
promote.yml to=stable group=<grupo>  canary → stable
canary.yml action=traffic weight_percent=0
canary.yml action=down
```

Atalho sem canary: `promote.yml to=stable from=rc group=<grupo>`.

## Rollback

Reverta o commit da versão e dê push:

```sh
git revert <commit "stable: ... -> X">
git push
```

O `deploy` instala a versão anterior. Versões antigas ficam em
`/srv/apps/<app>/releases/` (as 5 últimas), então a troca é rápida.

## Workflows

| Workflow | Quando |
|---|---|
| `deploy` | push em `versions_rc.yml`/`versions_stable.yml`, ou manual |
| `promote` | manual: copia um grupo para canary/stable e faz deploy |
| `canary` | manual: sobe/desce o pool canary, muda o tráfego, tira imagem |
| `rc` | manual: redeploy do rc |
| `image` | manual: gera a imagem Packer das apps (precisa de Packer no monitoring) |

Todos rodam o Ansible **no monitoring** via
`.github/actions/run-on-monitoring`: pega a chave `pscloud-ssh-monitoring-priv`
no vault, faz checkout do mesmo commit em `~/pscloud` (clone criado pelo
`bootstrap.yml`) e executa.
