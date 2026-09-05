# live

```
live/
  root.hcl          backend, provider, compartment
  prod/env.hcl      valores do ambiente
  prod/network      VCN 10.20.0.0/16, subnets, route tables, NSGs, gateways, LPG
  prod/peering      LPG do lado da VCN existente (10.0.0.0/16)
  prod/identity     tag namespace, dynamic groups, policies
  prod/platform     vault, chaves SSH, secrets, bastion, bucket
  prod/database     MySQL
  prod/compute      maquinas da aplicacao
  prod/loadbalancer LB publico
  rc/env.hcl        valores do ambiente
  rc/compute        maquinas de teste, na rede do prod
  rc/loadbalancer   LB proprio, IP proprio, na rede do prod
```

RC nao cria rede nem banco: os units apontam para `../../prod/network` e
`../../prod/platform`. Um state por unit, com a chave igual ao caminho:
`prod/network/terraform.tfstate`, `rc/compute/terraform.tfstate`.

```sh
cd prod && terragrunt run --all apply
cd rc   && terragrunt run --all apply
terragrunt dag graph
```
