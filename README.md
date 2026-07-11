# Raio-X Lake: MinIO

Infraestrutura de object storage S3-compatible do projeto
`raio-x-engenharia`, executada em nó único na VPS `2.25.172.31`.

O MinIO armazena dados Parquet das camadas landing, raw, staging e
intermediate. PostgreSQL permanece reservado às tabelas gold: dimensões,
fatos e marts. Este repositório não modifica nem contém o stack Astro,
collectors ou dbt.

## Arquitetura

- MinIO single-node com dados persistidos em `/srv/raio-x/minio/data`.
- Rede Docker externa compartilhada: `raio-x-data`.
- Endpoint interno para o scheduler Astro: `http://minio:9000`.
- Buckets de produção e desenvolvimento com usuários e políticas segregados.
- Console e API vinculados somente a `127.0.0.1`; o acesso administrativo é
  feito por túnel SSH.

MinIO single-node na mesma VPS não oferece alta disponibilidade e não substitui
backup externo testado.

## Pré-requisitos

- Docker Engine com Docker Compose plugin.
- `just`.
- `openssl`.
- Permissão para criar a rede Docker e o diretório persistente.

## Uso rápido

Na VPS:

```sh
sudo install -d -m 0700 /srv/raio-x/minio/data
just up
```

O comando cria a rede `raio-x-data` quando necessário, gera `.env` com senha
root de alta entropia somente na VPS, inicia o MinIO e provisiona buckets,
políticas e usuários de aplicação.

```sh
just status
just down
just reset DELETE-MINIO-DATA
```

`just down` preserva os objetos. `just reset DELETE-MINIO-DATA` é destrutivo e
remove todos os objetos e credenciais de aplicação geradas.

## Acesso administrativo

Na máquina administrativa autorizada, abra o túnel:

```sh
ssh -N \
  -o ExitOnForwardFailure=yes \
  -L 9000:127.0.0.1:9000 \
  -L 9001:127.0.0.1:9001 \
  usuario@2.25.172.31
```

Depois, use `http://localhost:9000` para a API S3 e
`http://localhost:9001` para o console MinIO.

## Segurança

- Nunca versione `.env` ou `.minio.application.env`.
- Aplicações usam apenas as credenciais prod ou dev geradas pelo bootstrap;
  nunca a conta root do MinIO.
- HTTP público não é adequado para credenciais permanentes ou dados sensíveis.
- Caso a publicação direta seja necessária, permita as portas `9000` e `9001`
  somente para `200.97.62.226`; nunca use `0.0.0.0/0`.
- Mantenha backup externo por objeto e teste a restauração periodicamente.

Consulte [docs/minio.md](docs/minio.md) para instalação detalhada, firewall,
integração com Astro, backup, restore e rotação de credenciais.
