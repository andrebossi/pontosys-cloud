# Genral
API_Monitor_Client - banco global com endereços de connection, recebe requests de todas outras.

* instalar somente o runtime do dotnet 5.0.15
* instalar somente o runtime do dotnet 2.1.30

# Apps

## Config
dentro de cada pasta a config fica via um appsettings.json

instalar fontes da microsoft
```
instalar fontes microsoft
orator 10
arial
tahoma
```

## Logs da app

Já esta no graylog hospedado em outra VPS
subir victoria metrics no rust-desk

## Deploy de imagens

deploy do frontend, e feito commit na pasta build/{production,rc}/{ionic,flutter}

Deploy tem que ser unificado em backend e frontend

backend: build separado.
  - virtualstore | API
  - relatoriosapi | API
  - pixapi
  - entradaapi
  - dashsapi
  - cadastrosapi

Tradução das pastas e arquivos

Virtualstore Frontend - ionic - separado
* assets
* build
* index.html - raiz do nginx
* manifest.json

Virtualstore Frontend - flutter
* app - separado
app no mapeamento interno e flutter no repo

-----
Monitor Clientes - Frontend flutter - empacotar separado.
* monitorclientes - separado

Monitor Clientes backend
* monitorclientesapi - separado
* geradorrelatoriosapi - separado