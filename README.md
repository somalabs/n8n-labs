# n8n-labs

n8n self-hosted em duas VMs do GCP (projeto `soma-ai-hub`, `us-central1`), com o
banco no Cloud SQL:

| Ambiente | VM         | Zona            | Máquina       | Modo                             | URL (só na VPN)                    | Banco (Cloud SQL `n8n`) |
| -------- | ---------- | --------------- | ------------- | -------------------------------- | ---------------------------------- | ----------------------- |
| prod     | `n8n-prod` | `us-central1-a` | e2-standard-4 | queue (main + redis + 2 workers) | `http://n8n-prod.somalabs.com.br` | `n8n_prod` / `postgres` |
| dev      | `n8n-dev`  | `us-central1-f` | e2-medium     | regular (processo único)         | `http://n8n-dev.somalabs.com.br`  | `n8n_dev` / `postgres`  |

Tudo roda em Docker Compose na VM, em `/opt/n8n`. Um único
[docker-compose.yml](docker-compose.yml) serve os dois ambientes; o que muda é o
arquivo de ambiente (`envs/prod.env`, `envs/dev.env` — **locais, fora do git**;
os modelos versionados são [envs/prod.env.example](envs/prod.env.example) e
[envs/dev.env.example](envs/dev.env.example)) mais os secrets, que vivem no
Secret Manager.

```
VPN ──DNS interno──▶ VM :80 ──▶ n8n main :5678 ──TLS──▶ Cloud SQL `n8n` (Postgres 18, IP privado)
                                    │
                         (prod)     ├──▶ redis ──▶ n8n-worker ×2
```

Não há proxy nem TLS na VM: o DNS `n8n-<env>.somalabs.com.br` é um registro A
para o **IP interno** da VM, só alcançável pela VPN, e o n8n publica a porta 80
direto no host. O Postgres não roda mais em container — é a instância Cloud SQL
`n8n` (IP privado `10.232.168.6` na Shared VPC `soma-network`), com um database
por ambiente e o usuário `postgres` que já existe nela — nenhum usuário é criado.

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

Isso exige o papel `roles/iap.tunnelResourceAccessor` no projeto. O deploy
pelo Cloud Build já usa esse caminho (ver [cloudbuild.yaml](cloudbuild.yaml) e
[Deploy pelo Cloud Build](#deploy-pelo-cloud-build)).

## 2. Subindo um ambiente do zero

Os passos abaixo valem para `ENV=prod` e `ENV=dev`. Cada um roda **uma vez** por
ambiente, exceto o `deploy`.

**2.0. Crie o env file local.** `cp envs/<env>.env.example envs/<env>.env` e
ajuste se precisar. Ele não vai para o git.

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
./scripts/secrets.sh prod set POSTGRES_PASSWORD   # senha do usuário postgres do Cloud SQL (pede no terminal)
make secrets ENV=prod
```

O primeiro comando grava `n8n-prod-postgres-password` com a senha do usuário
existente no Cloud SQL (`POSTGRES_USER`); ela nunca é gerada. O `make secrets`
cria `n8n-prod-encryption-key` e `n8n-prod-jwt-secret` com valores aleatórios e
recusa continuar se a senha do banco não estiver cadastrada. Nunca sobrescreve
um secret que já existe.

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

O deploy garante os secrets, cria no Cloud SQL o database do ambiente se
ainda não existir e confere que `POSTGRES_USER` existe lá, renderiza o
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

### Deploy pelo Cloud Build

Opcional. Roda **o mesmo** `scripts/deploy.sh`, só que num worker do Cloud
Build (projeto `soma-ai-hub`, `us-central1`) em vez da sua máquina: não
precisa de VPN, gcloud local nem chave ssh sua na VM. O worker entra pelo IAP e
roda como a service account `vm-deploy@soma-ai-hub`. A configuração está em
[cloudbuild.yaml](cloudbuild.yaml); os atalhos, em
[scripts/cloudbuild.sh](scripts/cloudbuild.sh).

**Uma vez por ambiente** (precisa de Owner ou dos papéis para IAM, Secret
Manager e Cloud Build):

```bash
make cloudbuild-setup ENV=prod
```

Idempotente. Garante os papéis da SA `vm-deploy` (`compute.instanceAdmin.v1`,
`iam.serviceAccountUser`, `iap.tunnelResourceAccessor`, `secretmanager.admin`,
`secretmanager.secretAccessor`, `cloudsql.admin`, `logging.logWriter`, e
leitura do bucket `soma-ai-hub_cloudbuild`), confere
que o repo `somalabs/n8n-labs` está vinculado à conexão GitHub
`github-somalabs` (2ª geração), copia `envs/prod.env` para o secret
`n8n-prod-env-file` e cria o trigger `n8n-deploy-prod` (branch `main`,
substituição `_ENV=prod`, SA `vm-deploy`).

Os dois triggers (`n8n-deploy-dev`, `n8n-deploy-prod`) disparam **sozinhos a
cada push em `main`** — um push faz deploy de dev e de prod ao mesmo tempo.
Também dá para disparar na mão com `make cloudbuild-deploy ENV=<env>` ou pelo
console (Cloud Build › Triggers › Run).

**Toda vez:**

```bash
make cloudbuild-deploy ENV=prod      # sincroniza envs/prod.env → secret, dispara o trigger e segue o log
make cloudbuild-submit ENV=dev       # idem, mas com a sua árvore local (gcloud builds submit), sem push
make cloudbuild-builds ENV=prod      # últimos builds do ambiente
make cloudbuild-log    ENV=prod      # log do último build (ou ID=<build-id>)
```

`cloudbuild-submit` serve para testar mudanças no próprio pipeline
(`cloudbuild.yaml`, `scripts/`) antes de ir para `main`: sobe a árvore local
para o bucket `soma-ai-hub_cloudbuild` (respeitando o `.gitignore`, então os
`envs/*.env` ficam de fora) e roda o mesmo build. Exige que a SA `vm-deploy`
leia esse bucket (`roles/storage.objectViewer` nele; o `cloudbuild-setup`
concede).

O trigger só constrói o que está na branch `main` do GitHub: **o push já é o
deploy**. Mudanças no compose ou nos scripts que
ainda estão só na sua máquina não entram no build (outra branch:
`CLOUDBUILD_BRANCH=minha-branch make cloudbuild-deploy ENV=dev`). Já o
`envs/<env>.env` é lido do secret, e o `cloudbuild-deploy` envia uma versão
nova só quando o conteúdo local mudou — o arquivo na sua máquina continua sendo
a fonte da verdade. Mudou só o env file? Rode `make cloudbuild-deploy
ENV=<env>` (ou `./scripts/secrets.sh <env> env-file` e um push): o push sozinho
não enxerga o seu arquivo local.

Quem dispara na mão precisa de `roles/cloudbuild.builds.editor` no projeto e
de `iam.serviceAccounts.actAs` na SA `vm-deploy` (`roles/iam.serviceAccountUser`
nela). Como prod também sobe a cada push em `main`, trate a branch como
produção: teste em outra branch (`CLOUDBUILD_BRANCH=minha-branch make
cloudbuild-deploy ENV=dev`) ou com `make cloudbuild-submit ENV=dev` antes de
dar merge, e faça `make backup ENV=prod` antes de subir uma versão nova do n8n.

O build faz dois passos: `validate` (`docker compose config` com o env file
real e secrets de mentira, igual ao `make validate`) e `deploy`
(`scripts/deploy.sh <env>` com `SSH_VIA_IAP=1` e `SSH_USER=cloudbuild` — o
container roda como root e a VM recusa root por ssh, então a chave efêmera
entra nos metadados como usuário `cloudbuild`). Timeout de 15 min. Os logs
ficam só no Cloud Logging (`CLOUD_LOGGING_ONLY`); `make cloudbuild-deploy`
os lê de lá enquanto segue o build.

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
ambientes com o usuário que já existe nela:

| Ambiente | `POSTGRES_DB` | `POSTGRES_USER` | Senha (Secret Manager)      |
| -------- | ------------- | --------------- | --------------------------- |
| prod     | `n8n_prod`    | `postgres`      | `n8n-prod-postgres-password` |
| dev      | `n8n_dev`     | `postgres`      | `n8n-dev-postgres-password`  |

Host, porta, database e usuário ficam em `envs/<env>.env`
(`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`);
`POSTGRES_VERSION` é a versão do client `psql`/`pg_dump` que a VM usa em
backup/restore (acompanhe a major da instância).

[scripts/cloudsql.sh](scripts/cloudsql.sh) (`make setup-db`, chamado também
pelo `deploy`) cria o database pela API se faltar e confere que `POSTGRES_USER`
existe na instância. **Nunca cria nem altera usuário ou senha.** Se a senha do
usuário mudar no Cloud SQL, grave a nova com
`./scripts/secrets.sh <env> set POSTGRES_PASSWORD` e rode `make deploy`.

Quem roda o deploy precisa de `roles/cloudsql.admin` no projeto (você, ou a
SA `vm-deploy` no caso do Cloud Build).

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
envs/*.env.example        modelos versionados; copie para envs/<env>.env (local, fora do git)
scripts/lib.sh            projeto, instância Cloud SQL, mapa env→VM, helpers de ssh (direto ou via IAP)
scripts/bootstrap.sh      roda scripts/vm/bootstrap.sh na VM via ssh
scripts/gcp-setup.sh      APIs, disco, snapshot, checagem de DNS
scripts/secrets.sh        Secret Manager: ensure | render | set | env-file (cópia do envs/<env>.env para o Cloud Build)
scripts/cloudsql.sh       Cloud SQL: ensure (database do ambiente; confere o usuário) | info
scripts/deploy.sh         secrets, cloudsql, renderiza .env, copia, compose up, healthcheck
scripts/cloudbuild.sh     Cloud Build: setup (papéis, secret do env file, trigger) | run | builds | log
scripts/ops.sh            status, logs, ssh, psql, restart, backup, restore, migrate-db, fetch-backup, down
scripts/vm/bootstrap.sh   roda na VM: docker, cron, logs, updates
scripts/vm/lib-pg.sh      roda na VM: psql/pg_dump/pg_restore em container, apontados para o Cloud SQL
scripts/vm/backup.sh      roda na VM (cron): pg_dump + exports + retenção
scripts/vm/restore.sh     roda na VM: restaura um dump no Cloud SQL
scripts/vm/psql.sh        roda na VM: psql interativo
scripts/vm/migrate-to-cloudsql.sh  roda na VM (uma vez): volume postgres antigo → Cloud SQL
cloudbuild.yaml           deploy manual pelo Cloud Build (opcional; trigger n8n-deploy-<env>)
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
- **`cloudsql.sh ensure` só cria database.** Usuário e senha são os que já
  existem no Cloud SQL; um deploy nunca cria usuário nem troca senha.
- **Env files fora do git.** `envs/*.env` são locais (`.gitignore`); o repo só
  tem os `.example`. O Cloud Build os lê do secret `n8n-<env>-env-file`, que
  `make cloudbuild-deploy` sincroniza a partir do seu arquivo local (ver
  [cloudbuild.yaml](cloudbuild.yaml)).
- **`N8N_RUNNERS_ENABLED=true`, `N8N_BLOCK_ENV_ACCESS_IN_NODE=true`.** Nós Code
  rodam isolados e não leem as variáveis de ambiente do container (onde estão
  a senha do banco e a encryption key).
- **Pruning de execuções.** Prod guarda 14 dias/50 k; dev 3 dias/10 k. Sem isso
  o banco só cresce.
- **`N8N_DIAGNOSTICS_ENABLED=false`.** Sem telemetria para a n8n GmbH.
- **Firewall.** A `soma-network` é fechada: a regra `allow-internal-in` libera
  qualquer porta para `10.0.0.0/8`, `192.168.0.0/16` e `172.16.0.0/12` (VPN e
  ranges internos); a 22 também entra pelo range do IAP. Não há regra para
  `0.0.0.0/0`. Acesso automatizado (Cloud Build) entra pelo IAP.
- **SSH efêmero.** Os scripts passam `--ssh-key-expire-after=1h` ao gcloud, então
  a chave de quem roda (inclusive de workers descartáveis do Cloud Build) fica
  registrada nos metadados do projeto só por uma hora. Ajuste com `SSH_KEY_TTL=`.
- **Cloud Build em vez de GitHub Actions.** O deploy automatizado fica no
  mesmo projeto das VMs: sem chave JSON de service account guardada no GitHub,
  sem cópia do env file em secret do repositório — o build já roda como a SA
  `vm-deploy` e lê o Secret Manager direto. Os dois ambientes fazem deploy a
  cada push em `main`, então `main` é produção: o que ainda não está pronto
  fica em outra branch.
- **Logs.** `json-file` com 20 MB × 5 por container (`/etc/docker/daemon.json`);
  o Ops Agent já está na VM (`enable-osconfig`) se quiser mandar para o Cloud Logging.

## 12. Problemas conhecidos

- **`healthz` não responde no deploy.** Quase sempre é o n8n esperando o banco.
  `make logs ENV=x SVC=n8n`: erro de autenticação → o secret
  `n8n-<env>-postgres-password` não é a senha atual do usuário no Cloud SQL
  (ver [seção 5](#5-banco-de-dados-cloud-sql));
  timeout → `POSTGRES_HOST` errado ou a VM não está na mesma VPC da instância.
- **`gcloud compute ssh` trava / `Connection timed out` na porta 22.** Você está
  fora da VPN. Use `SSH_VIA_IAP=1` — ver [Pré-requisitos](#1-pré-requisitos).
  Se der `403` / `Permission denied` no túnel, falta
  `roles/iap.tunnelResourceAccessor` para quem está rodando (no Cloud Build, a
  SA `vm-deploy`; `make cloudbuild-setup` concede).
- **Cloud Build falha em `validate` com "secret vazio" ou `NOT_FOUND`.** O
  secret `n8n-<env>-env-file` não existe ou está sem versão: rode
  `make cloudbuild-setup ENV=<env>` (ou `./scripts/secrets.sh <env> env-file`).
  Se o build reclama de permissão ao disparar, falta `iam.serviceAccounts.actAs`
  na SA `vm-deploy` para o seu usuário.
- **Cloud Build fez deploy de código velho.** O trigger constrói a branch
  `main` do GitHub, não a sua cópia local. Faça push (ou use
  `CLOUDBUILD_BRANCH=`).
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
