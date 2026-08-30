# app_image

Ciclo de vida da imagem dourada, com o SDK Python da OCI, usando a identidade
da própria VM de monitoramento (instance principal) — sem chave em disco.

É a ponte entre o Packer e o `app_canary`.

```bash
image list                                  # imagens da família + qual pool usa cada uma
image release --latest                      # aponta o pool canário para a mais nova
image release --image-id ocid1.image...
image prune --keep 3 --dry-run
```

Pelo Ansible:

```bash
ansible-playbook deploy.yml -e image_action=release
ansible-playbook deploy.yml -e image_action=prune
```

## release

Instance configuration é **imutável** na OCI: não dá para editar, só criar
outra. O `release` clona a que o pool já usa trocando apenas o `image_id` —
montar do zero arriscaria errar shape, subnet, NSG ou cloud-init, e o erro só
apareceria quando a instância subisse quebrada.

Grava `pscloud_pool` e `pscloud_release` no `metadata`, que é de onde o
cloud-init tira os rótulos da métrica. Sem eles, canário e estável ficam
indistinguíveis no VictoriaMetrics.

## prune

"Manter as N mais novas" por data não basta: a imagem em produção pode ser mais
antiga que vários builds que falharam depois dela. O conjunto protegido é
`N mais novas` **mais** toda imagem referenciada por um instance pool.

O piso de idade (2h por padrão) evita apagar um build recém-saído do Packer que
ainda não foi promovido a nenhum pool.

## Fluxo completo

```
packer build          ->  imagem com tags pscloud_family/built_by/release
image release --latest -> instance configuration nova, pool canário apontado
canary up              -> 1 VM canária, drenada
canary shift 10 / 25 / 50
canary promote         -> pool estável assume a imagem
image prune            -> mantém as 3 últimas
```
