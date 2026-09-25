# n8n-labs

n8n self-hosted em duas VMs do GCP (projeto `soma-ai-hub`, `us-central1`), com o
banco no Cloud SQL:

| Ambiente | VM         | Zona            | Máquina       | Modo                             | URL (só na VPN)                    | Banco (Cloud SQL `n8n`) |
| -------- | ---------- | --------------- | ------------- | -------------------------------- | ---------------------------------- | ----------------------- |
| prod     | `n8n-prod` | `us-central1-a` | e2-standard-4 | queue (main + redis + 2 workers) | `http://n8n-prod.somalabs.com.br` | `n8n_prod` / `n8n_prod` |
| dev      | `n8n-dev`  | `us-central1-f` | e2-medium     | regular (processo único)         | `http://n8n-dev.somalabs.com.br`  | `n8n_dev` / `n8n_dev`   |

Tudo roda em Docker Compose na VM, em `/opt/n8n`. Um único
[docker-compose.yml](docker-compose.yml) serve os dois ambientes; o que muda é o
arquivo de ambiente ([envs/prod.env](envs/prod.env), [envs/dev.env](envs/dev.env))
mais os secrets, que vivem no Secret Manager.

```
VPN ──DNS interno──▶ VM :80 ──▶ n8n main :5678 ──TLS──▶ Cloud SQL `n8n` (Postgres 18, IP privado)
                                    │
                         (prod)     ├──▶ redis ──▶ n8n-worker ×2
```

Não há proxy nem TLS na VM: o DNS `n8n-<env>.somalabs.com.br` é um registro A
para o **IP interno** da VM, só alcançável pela VPN, e o n8n publica a porta 80
direto no host. O Postgres não roda mais em container — é a instância Cloud SQL
`n8n` (IP privado `10.232.168.6` na Shared VPC `soma-network`), com um database
e um usuário por ambiente.

## Índice

1. [Pré-requisitos](#1-pré-requisitos)
2. [Subindo um ambiente do zero](#2-subindo-um-ambiente-do-zero)
3. [Dia a dia](#3-dia-a-dia)
4. [Atualizar a versão do n8n](#4-atualizar-a-versão-do-n8n)
5. [Banco de dados (Cloud SQL)](#5-banco-de-dados-cloud-sql)
6. [Backups e restore](#6-backups-e-restore)
7. [Migrar do Postgres em container para o Cloud SQL](#7-migrar-do-postgres-em-container-para-o-cloud-sql)
8. [Levar workflows de dev para prod](#8-levar-workflows-de-dev-para-prod)
9. [DNS e acesso](#9-dns-e-acesso)
10. [Estrutura do repositório](#10-estrutura-do-repositório)
11. [Decisões e detalhes](#11-decisões-e-detalhes)
12. [Problemas conhecidos](#12-problemas-conhecidos)

---

## 1. Pré-requisitos

Na sua máquina:

- `gcloud` autenticado (`gcloud auth login`) com acesso ao projeto `soma-ai-hub`
  e permissão para Compute, Secret Manager, Cloud SQL Admin (criar database e
  usuário na instância `n8n`) e SSH nas VMs.
- `docker` (opcional, só para validar o compose antes de mandar para a VM).
- `make`, `curl`, `openssl`, `dig`.

Na primeira vez que rodar `gcloud compute ssh`, ele cria uma chave em
`~/.ssh/google_compute_engine` e a registra na VM. Aceite os prompts.

**Rede.** As VMs ficam na Shared VPC `soma-network` (projeto
`soma-infra-network`). O firewall dela (`allow-internal-in`) libera qualquer
porta para a rede da empresa (VPN e ranges internos), e a porta 22 para o range
do Identity-Aware Proxy (`allow-ingress-from-iap`, `35.235.240.0/20`). De fora
da VPN nem o IP público nem o DNS interno respondem. Nesse caso use o túnel IAP
em qualquer alvo do Makefile:

```bash
SSH_VIA_IAP=1 make deploy ENV=dev
SSH_VIA_IAP=1 make ssh ENV=prod
```

Isso exige o papel `roles/iap.tunnelResourceAccessor` no projeto. O GitHub
Actions já usa esse caminho por padrão (ver [.github/workflows/deploy.yml](.github/workflows/deploy.yml)).

## 2. Subindo um ambiente do zero

Os passos abaixo valem para `ENV=prod` e `ENV=dev`. Cada um roda **uma vez** por
ambiente, exceto o `deploy`.

**2.1. Confira o DNS.** `n8n-<env>.somalabs.com.br` precisa ser um registro A
para o IP interno da VM (`./scripts/print-vm.sh <env> internal-ip`). O
`setup-gcp` abaixo confere isso no final.

**2.2. Prepare o lado GCP** (não reinicia a VM):

```bash
make setup-gcp ENV=prod
```

Faz, de forma idempotente: habilita as APIs (Secret Manager, Compute, Cloud SQL
Admin), aumenta o disco de boot (prod 50 GB, dev 20 GB), cria e anexa um
agendamento de snapshot diário do disco e confere o DNS.

**2.3. Crie os secrets:**

```bash
make secrets ENV=prod
```

Cria `n8n-prod-postgres-password`, `n8n-prod-encryption-key` e
`n8n-prod-jwt-secret` com valores aleatórios. Nunca sobrescreve um secret que já
existe.

> A **encryption key** criptografa todas as credenciais salvas no n8n. Se ela
> se perder, as credenciais viram lixo. Ela só existe no Secret Manager e no
> `.env` da VM; não a copie para outro lugar, não a rotacione.

**2.4. Prepare a VM** (Docker, limite de logs, cron de backup, updates de
segurança, expansão do filesystem):

```bash
make bootstrap ENV=prod
```

**2.5. Deploy:**

```bash
make deploy ENV=prod
```

O deploy garante os secrets, cria no Cloud SQL o database e o usuário do
ambiente se ainda não existirem (com a senha do Secret Manager), renderiza o
`.env` (env file + secrets), copia tudo para `/opt/n8n`, faz
`docker compose pull && up -d` e espera `http://127.0.0.1:80/healthz`
responder de dentro da VM. Na primeira subida o n8n cria as tabelas no Cloud
SQL sozinho (migrations).

Se esse ambiente já rodava com o Postgres em container, siga a
[seção 7](#7-migrar-do-postgres-em-container-para-o-cloud-sql) logo depois.

**2.6. Crie o usuário owner.** Abra a URL do ambiente (na VPN). Na primeira
visita o n8n pede para criar a conta de administrador. Faça isso logo: até então
a instância aceita o primeiro que chegar.

## 3. Dia a dia

```bash
make status  ENV=prod             # containers, disco, memória
make logs    ENV=prod             # todos os serviços
make logs    ENV=prod SVC=n8n-worker
make restart ENV=prod SVC=n8n
make ssh     ENV=prod
make psql    ENV=prod             # psql no database deste ambiente no Cloud SQL
make db-info ENV=prod             # instância, databases e usuários no Cloud SQL
make deploy-config ENV=prod       # reaplica envs/prod.env sem baixar imagem
```

Mudou algo em `envs/<env>.env` ou no compose? `make deploy`. O compose só
recria o que mudou.

Todos os alvos do Makefile são só atalhos para [scripts/](scripts/), que aceitam
o ambiente como primeiro argumento (`./scripts/ops.sh prod status`).

## 4. Atualizar a versão do n8n

1. Mude `N8N_VERSION` em `envs/dev.env` e rode `make deploy ENV=dev`.
2. Teste em dev. Migrations de banco rodam sozinhas ao subir.
3. Rode `make backup ENV=prod` (o dump de antes da migration é o caminho de
   volta).
4. Mude `N8N_VERSION` em `envs/prod.env` e rode `make deploy ENV=prod`.

Voltar uma versão **depois** que a migration rodou não é seguro: restaure o dump
do passo 3 com `make restore` e só então volte o `N8N_VERSION`.

Releases: <https://github.com/n8n-io/n8n/releases>. Use só versões sem sufixo
(`2.38.7`, não `next`/`nightly`).

## 5. Banco de dados (Cloud SQL)

Uma instância só, `n8n` (`soma-ai-hub:us-central1:n8n`, Postgres 18,
`db-custom-2-8192`, regional, só IP privado, TLS obrigatório), atende os dois
ambientes:

| Ambiente | `POSTGRES_DB` | `POSTGRES_USER` | Senha (Secret Manager)      |
| -------- | ------------- | --------------- | --------------------------- |
| prod     | `n8n_prod`    | `n8n_prod`      | `n8n-prod-postgres-password` |
| dev      | `n8n_dev`     | `n8n_dev`       | `n8n-dev-postgres-password`  |

Host, porta, database e usuário ficam em `envs/<env>.env`
(`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`);
`POSTGRES_VERSION` é a versão do client `psql`/`pg_dump` que a VM usa em
backup/restore (acompanhe a major da instância).

[scripts/cloudsql.sh](scripts/cloudsql.sh) (`make setup-db`, chamado também
pelo `deploy`) cria database e usuário pela API se faltarem e **nunca altera o
que já existe** — se você rotacionar `n8n-<env>-postgres-password` com
`./scripts/secrets.sh <env> set POSTGRES_PASSWORD`, aplique a mesma senha no
usuário pelo console (instância `n8n` › Users) ou com
`gcloud sql users set-password`, e então `make deploy`.

O n8n conecta com `DB_POSTGRESDB_SSL_ENABLED=true` e
`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false`: a instância exige TLS, mas o
certificado dela é emitido para o connection name, não para o IP, então a
verificação de hostname falharia. O tráfego é cifrado e nunca sai da VPC.

A VM não tem `psql` instalado: [scripts/vm/lib-pg.sh](scripts/vm/lib-pg.sh)
roda cada comando num container `postgres:<POSTGRES_VERSION>-alpine`
descartável já apontado para o banco do ambiente (`make psql`).

## 6. Backups e restore

Três camadas, independentes:

| Camada                     | O que é                                                 | Onde                                 | Retenção          |
| -------------------------- | ------------------------------------------------------- | ------------------------------------ | ----------------- |
| Backup do Cloud SQL        | Backup automático da instância inteira (dev + prod) e PITR | GCP › SQL › `n8n` › Backups       | conforme a instância |
| Dump diário (cron 03:30)   | `pg_dump` do database do ambiente + export de workflows e credenciais | `/opt/n8n/backups` na VM | prod 14d / dev 7d |
| Snapshot do disco          | Imagem da VM (volume `n8n_data`, dumps), 06:00 UTC      | GCP › Compute › Snapshots            | prod 14d / dev 7d |

```bash
make backup  ENV=prod                        # roda o dump agora
make backups ENV=prod                        # lista
make fetch-backup ENV=prod FILE=n8n-n8n-prod-20260914-033000.dump   # baixa para ./backups/
make restore ENV=prod FILE=n8n-n8n-prod-20260914-033000.dump        # restaura no Cloud SQL
```

**Restore do banco** ([scripts/vm/restore.sh](scripts/vm/restore.sh)): para o
n8n, zera o schema `public` do database do ambiente (não dropa o database, que
pertence à instância compartilhada), restaura o dump e sobe de novo. Pede
confirmação digitando o host. A encryption key da VM precisa ser a mesma que
gerou o dump. O restore de um ambiente não toca no outro.

**Restore de desastre** (VM perdida): o banco está no Cloud SQL, então só o
volume `n8n_data` (chave em `config`, binários) e os dumps locais vivem na VM.
Crie uma VM nova a partir do snapshot mais recente, ajuste `carregar_env` em
[scripts/lib.sh](scripts/lib.sh) se o nome/zona mudarem, aponte o DNS para o
novo IP interno e rode `make deploy`.

**Copiar dumps para um bucket** (opcional): a SA padrão das VMs só tem scope de
_leitura_ no Storage. Para habilitar escrita é preciso parar a VM e rodar
`gcloud compute instances set-service-account n8n-prod --zone us-central1-a --scopes storage-rw,logging-write,monitoring-write`,
criar o bucket e preencher `BACKUP_BUCKET` no env file. O `backup.sh` já faz a
cópia quando a variável está definida.

## 7. Migrar do Postgres em container para o Cloud SQL

Para um ambiente que já rodava a versão anterior deste repo (postgres em
container na VM). Uma vez só, nesta ordem:

```bash
make deploy     ENV=dev   # sobe o compose novo: n8n aponta para o Cloud SQL (vazio)
make migrate-db ENV=dev   # postgres antigo → Cloud SQL
```

O `deploy` derruba os containers `n8n-postgres` e `n8n-caddy` (saíram do
compose), mas o volume `n8n_postgres_data` fica. O `migrate-db`
([scripts/vm/migrate-to-cloudsql.sh](scripts/vm/migrate-to-cloudsql.sh)) sobe um
Postgres 16 descartável em cima desse volume, gera
`/opt/n8n/backups/pre-cloudsql-<data>.dump` e chama o `restore.sh`, que para o
n8n, zera o schema no Cloud SQL, restaura e sobe de novo. Pede confirmação com
o nome do host.

Depois de conferir que workflows e credenciais estão lá (a encryption key não
mudou, então as credenciais continuam válidas), remova o volume antigo na VM:

```bash
make ssh ENV=dev
sudo docker volume rm n8n_postgres_data
```

Se o postgres antigo tinha usuário/database diferentes de `n8n`/`n8n` ou outra
versão, passe `LEGACY_USER`, `LEGACY_DB`, `LEGACY_VERSION` ao rodar o script na
VM.

## 8. Levar workflows de dev para prod

O backup diário já gera `*-workflows.json` (portável) e `*-credentials.json`
(criptografado com a chave de dev, portanto **não** importável em prod). Para
promover:

```bash
make backup ENV=dev && make backups ENV=dev
make fetch-backup ENV=dev FILE=n8n-n8n-dev-<data>-workflows.json
# na VM de prod:
make ssh ENV=prod
sudo docker cp ~/n8n-n8n-dev-<data>-workflows.json n8n-main:/tmp/wf.json
sudo docker compose -f /opt/n8n/docker-compose.yml exec n8n n8n import:workflow --input=/tmp/wf.json
```

As credenciais precisam ser recriadas em prod pela UI (ou via export com
`--decrypted` em dev, tratado como material sensível). Para algo mais elaborado
o n8n oferece _Source Control_ com Git, mas é recurso do plano Enterprise.

## 9. DNS e acesso

- `n8n-prod.somalabs.com.br → 10.0.96.72` e `n8n-dev.somalabs.com.br → 10.0.96.73`
  (IPs internos das VMs). Só resolve/alcança quem está na VPN.
- O n8n publica `N8N_PUBLISH_PORT` (80) direto no host, HTTP puro
  (`N8N_PROTOCOL=http`, `N8N_SECURE_COOKIE=false`). Para outra porta, mude
  `N8N_PUBLISH_PORT` em `envs/<env>.env`; a URL passa a levar `:porta`.
- Para trocar o host: ajuste o registro A, troque `N8N_HOST` e `make deploy`.
  Webhooks já registrados em serviços externos apontam para o host antigo e
  precisam ser reativados (desativar/ativar o workflow).
- Se um dia quiser TLS: o Let's Encrypt não alcança a VM (IP interno, firewall
  fechado), então seria certificado interno da empresa num proxy na frente do
  n8n, com `N8N_PROTOCOL=https`, `N8N_SECURE_COOKIE=true` e `N8N_PROXY_HOPS=1`.

## 10. Estrutura do repositório

```
docker-compose.yml        stack (n8n, redis*, n8n-worker*)  *profile "queue"
envs/prod.env, dev.env    config não sensível por ambiente (versionada)
scripts/lib.sh            projeto, instância Cloud SQL, mapa env→VM, helpers de ssh (direto ou via IAP)
scripts/bootstrap.sh      roda scripts/vm/bootstrap.sh na VM via ssh
scripts/gcp-setup.sh      APIs, disco, snapshot, checagem de DNS
scripts/secrets.sh        Secret Manager: ensure | render | set
scripts/cloudsql.sh       Cloud SQL: ensure (database + usuário do ambiente) | info
scripts/deploy.sh         secrets, cloudsql, renderiza .env, copia, compose up, healthcheck
scripts/ops.sh            status, logs, ssh, psql, restart, backup, restore, migrate-db, fetch-backup, down
scripts/vm/bootstrap.sh   roda na VM: docker, cron, logs, updates
scripts/vm/lib-pg.sh      roda na VM: psql/pg_dump/pg_restore em container, apontados para o Cloud SQL
scripts/vm/backup.sh      roda na VM (cron): pg_dump + exports + retenção
scripts/vm/restore.sh     roda na VM: restaura um dump no Cloud SQL
scripts/vm/psql.sh        roda na VM: psql interativo
scripts/vm/migrate-to-cloudsql.sh  roda na VM (uma vez): volume postgres antigo → Cloud SQL
.github/workflows/        deploy manual pelo GitHub (opcional, ver comentários)
Makefile                  atalhos; exige ENV=prod|dev
local-files/              montado em /files no n8n (nós Read/Write Files)
```

Na VM, `/opt/n8n` espelha isso: `docker-compose.yml`, `scripts/`, `.env` (600,
root), `backups/`, `local-files/`.

## 11. Decisões e detalhes

- **Um compose, dois envs.** Prod liga o profile `queue` (`COMPOSE_PROFILES=queue`)
  e `EXECUTIONS_MODE=queue`; dev não. Evita dois arquivos quase iguais divergindo.
- **Cloud SQL em vez de Postgres em container.** Backup automático, PITR, HA
  regional e disco que não briga com a VM. Uma instância para os dois
  ambientes, isolados por database/usuário. `DB_POSTGRESDB_HOST` aponta para o
  IP privado; a VM chega lá pela própria Shared VPC, sem proxy.
- **Sem Caddy, sem TLS.** O DNS é interno e o firewall só deixa a VPN entrar,
  então o Let's Encrypt nunca conseguiria emitir. O n8n publica a 80 direto no
  host. Ver [seção 9](#9-dns-e-acesso) para o caminho com certificado interno.
- **Secrets fora do git e fora da VM até o deploy.** O `deploy.sh` lê do Secret
  Manager com _sua_ credencial e grava o `.env` na VM com permissão 600. A SA da
  VM não precisa de acesso ao Secret Manager (e não tem).
- **`cloudsql.sh ensure` não altera nada que já exista**, pelo mesmo motivo do
  `secrets.sh ensure`: um deploy nunca troca senha de banco por baixo dos panos.
- **`N8N_RUNNERS_ENABLED=true`, `N8N_BLOCK_ENV_ACCESS_IN_NODE=true`.** Nós Code
  rodam isolados e não leem as variáveis de ambiente do container (onde estão
  a senha do banco e a encryption key).
- **Pruning de execuções.** Prod guarda 14 dias/50 k; dev 3 dias/10 k. Sem isso
  o banco só cresce.
- **`N8N_DIAGNOSTICS_ENABLED=false`.** Sem telemetria para a n8n GmbH.
- **Firewall.** A `soma-network` é fechada: a regra `allow-internal-in` libera
  qualquer porta para `10.0.0.0/8`, `192.168.0.0/16` e `172.16.0.0/12` (VPN e
  ranges internos); a 22 também entra pelo range do IAP. Não há regra para
  `0.0.0.0/0`. Acesso automatizado (GitHub Actions) entra pelo IAP.
- **SSH efêmero.** Os scripts passam `--ssh-key-expire-after=1h` ao gcloud, então
  a chave de quem roda (inclusive de runners descartáveis do GitHub) fica
  registrada nos metadados do projeto só por uma hora. Ajuste com `SSH_KEY_TTL=`.
- **Logs.** `json-file` com 20 MB × 5 por container (`/etc/docker/daemon.json`);
  o Ops Agent já está na VM (`enable-osconfig`) se quiser mandar para o Cloud Logging.

## 12. Problemas conhecidos

- **`healthz` não responde no deploy.** Quase sempre é o n8n esperando o banco.
  `make logs ENV=x SVC=n8n`: erro de autenticação → a senha do usuário no Cloud
  SQL não bate com o secret (ver [seção 5](#5-banco-de-dados-cloud-sql));
  timeout → `POSTGRES_HOST` errado ou a VM não está na mesma VPC da instância.
- **`gcloud compute ssh` trava / `Connection timed out` na porta 22.** Você está
  fora da VPN (ou é o GitHub Actions). Use `SSH_VIA_IAP=1` — ver
  [Pré-requisitos](#1-pré-requisitos). Se der `403` / `Permission denied` no
  túnel, falta `roles/iap.tunnelResourceAccessor` para quem está rodando.
- **O navegador abre a URL mas o login não completa.** `N8N_SECURE_COOKIE` tem
  que ser `false` enquanto o acesso é HTTP; o compose já define. Se colocar um
  proxy com TLS na frente, inverta.
- **`permission denied` no docker sem sudo dentro da VM.** O bootstrap adiciona
  seu usuário ao grupo `docker`, mas só vale a partir do próximo login. Os
  scripts usam `sudo` justamente para não depender disso.
- **Disco não cresceu depois do `setup-gcp`.** Rode `make bootstrap` de novo (o
  passo de `growpart`/`resize2fs` é idempotente) ou reinicie a VM.
- **Worker em `unhealthy` logo após subir.** O worker espera o main ficar
  saudável; nos primeiros ~60 s é normal. Se persistir, veja se o redis está de pé.
