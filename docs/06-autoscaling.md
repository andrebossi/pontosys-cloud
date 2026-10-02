# 06 — Autoscaling

As apps rodam num **instance pool** (`infra/modules/app-tier`), atrás do load
balancer `pscloud-lb` (`144.22.172.90`, porta 80).

| | Hoje (`infra/live/prod/app-tier/terragrunt.hcl`) |
|---|---|
| Máquina | `VM.Standard.E4.Flex`, 1 OCPU, 6 GB |
| Pool stable | mínimo 1, máximo 2, nos 3 fault domains |
| Pool canary | 0 (só sobe com `canary.yml action=up`) |
| Escala para cima | CPU média > 70% **ou** memória média > 80% por 5 min |
| Escala para baixo | CPU média < 25% **e** memória média < 60% por 5 min |
| Espera entre escalas | 5 min |
| Drenagem ao remover | 120 s |

## Health check

O LB chama `GET /healthz` na porta 80 a cada 10 s (timeout 3 s, 3 falhas para
tirar). O nginx responde `200` sem consultar as apps, de propósito: se o banco
cair, as máquinas não saem todas do LB de uma vez.

Para saber se as **apps** estão de pé: `curl http://144.22.172.90/readyz`
(passa pela `monitorclientesapi`). Qualquer código que não seja 502 = ok.

```sh
oci lb backend-set-health get --load-balancer-id <id> --backend-set-name pscloud-bes-app
```

## O que uma máquina nova tem

Ela nasce da imagem (`PSCLOUD_APP_IMAGE_ID`, ou Ubuntu puro) e **não roda
Ansible sozinha**: entra no LB com `/healthz` respondendo, mas sem os segredos
(`/etc/dotnet-apps/*.env`) as APIs não sobem.

Depois de uma escala para cima, rode o *deploy* manual no canal `stable` (ou
`site.yml -l pool_stable` no monitoring). Enquanto isso não for automático,
mantenha `pool_max_size = 1` se não quiser máquinas incompletas no LB.

## Mudar

Edite `pool_min_size`, `pool_max_size` ou `autoscaling` em
`infra/live/prod/app-tier/terragrunt.hcl` e:

```sh
cd infra/live/prod/app-tier && terragrunt apply
```

As médias são de todas as máquinas do pool stable (métricas `oci_computeagent`
filtradas por `instancePoolId`). Memória não cai quando entra uma máquina nova
como a CPU cai: cada máquina roda todas as apps. Com as apps no ar, olhe a
memória de uma máquina sem carga e deixe `scale_in_memory` acima dela, senão o
pool nunca volta ao mínimo.

Escalar na mão (sem esperar CPU ou memória): mude `pool_min_size` ou use o console
(*Instance pools → pscloud-pool-stable → Edit size*).
