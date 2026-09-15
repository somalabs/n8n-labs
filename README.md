# n8n-labs

n8n self-hosted em duas VMs do GCP (projeto `soma-ai-hub`, `us-central1`):

| Ambiente | VM         | Zona            | Máquina         | Modo                          | URL                                 |
| -------- | ---------- | --------------- | --------------- | ----------------------------- | ----------------------------------- |
| prod     | `n8n-prod` | `us-central1-a` | e2-standard-4   | queue (main + redis + 2 workers) | `https://35.224.228.68.sslip.io` |
| dev      | `n8n-dev`  | `us-central1-f` | e2-medium       | regular (processo único)      | `https://136.116.231.86.sslip.io`   |

Tudo roda em Docker Compose na VM, em `/opt/n8n`. Um único
[docker-compose.yml](docker-compose.yml) serve os dois ambientes; o que muda é o
arquivo de ambiente ([envs/prod.env](envs/prod.env), [envs/dev.env](envs/dev.env))
mais os secrets, que vivem no Secret Manager.

```
internet ──443──▶ caddy (TLS Let's Encrypt) ──▶ n8n main :5678 ──▶ postgres 16
                                                   │
                                        (prod)     ├──▶ redis ──▶ n8n-worker ×2
```

## Índice

1. [Pré-requisitos](#1-pré-requisitos)
2. [Subindo um ambiente do zero](#2-subindo-um-ambiente-do-zero)
3. [Dia a dia](#3-dia-a-dia)
4. [Atualizar a versão do n8n](#4-atualizar-a-versão-do-n8n)
5. [Backups e restore](#5-backups-e-restore)
6. [Levar workflows de dev para prod](#6-levar-workflows-de-dev-para-prod)
7. [Domínio próprio](#7-domínio-próprio)
8. [Estrutura do repositório](#8-estrutura-do-repositório)
9. [Decisões e detalhes](#9-decisões-e-detalhes)
10. [Problemas conhecidos](#10-problemas-conhecidos)

---

## 1. Pré-requisitos

Na sua máquina:

- `gcloud` autenticado (`gcloud auth login`) com acesso ao projeto `soma-ai-hub`
  e permissão para Compute, Secret Manager e SSH nas VMs.
- `docker` (opcional, só para validar o compose antes de mandar para a VM).
- `make`, `curl`, `openssl`.

Na primeira vez que rodar `gcloud compute ssh`, ele cria uma chave em
`~/.ssh/google_compute_engine` e a registra na VM. Aceite os prompts.

## 2. Subindo um ambiente do zero

Os passos abaixo valem para `ENV=prod` e `ENV=dev`. Cada um roda **uma vez** por
ambiente, exceto o `deploy`.

**2.1. Preencha o e-mail do Let's Encrypt.** Em `envs/<env>.env`, coloque um
e-mail em `ACME_EMAIL=`. É obrigatório (o deploy recusa vazio); recebe avisos
de expiração de certificado.

**2.2. Prepare o lado GCP** (não reinicia a VM):

```bash
make setup-gcp ENV=prod
```

Faz, de forma idempotente: adiciona as tags `http-server`/`https-server` (as
regras de firewall da `soma-network` só liberam 80/443 para quem tem essas
tags), promove o IP efêmero a estático, aumenta o disco de boot (prod 50 GB,
dev 20 GB — os 10 GB de fábrica não bastam), cria e anexa um agendamento de
snapshot diário do disco e habilita a API do Secret Manager.

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

O deploy renderiza o `.env` (env file + secrets), copia tudo para
`/opt/n8n`, faz `docker compose pull && up -d` e espera `https://<host>/healthz`
responder. No primeiro deploy o Caddy emite o certificado — pode levar um
minuto; se o healthz estourar o tempo, olhe `make logs ENV=prod SVC=caddy`.

**2.6. Crie o usuário owner.** Abra a URL do ambiente. Na primeira visita o
n8n pede para criar a conta de administrador. Faça isso logo: até então a
instância aceita o primeiro que chegar.

## 3. Dia a dia

```bash
make status  ENV=prod             # containers, disco, memória
make logs    ENV=prod             # todos os serviços
make logs    ENV=prod SVC=n8n-worker
make restart ENV=prod SVC=n8n
make ssh     ENV=prod
make deploy-config ENV=prod       # reaplica envs/prod.env sem baixar imagem
```

Mudou algo em `envs/<env>.env`, no compose ou no Caddyfile? `make deploy`. O
compose só recria o que mudou.

Todos os alvos do Makefile são só atalhos para [scripts/](scripts/), que aceitam
o ambiente como primeiro argumento (`./scripts/ops.sh prod status`).

## 4. Atualizar a versão do n8n

1. Mude `N8N_VERSION` em `envs/dev.env` e rode `make deploy ENV=dev`.
2. Teste em dev. Migrations de banco rodam sozinhas ao subir.
3. Rode `make backup ENV=prod` (o dump de antes da migration é o caminho de
   volta).
4. Mude `N8N_VERSION` em `envs/prod.env` e rode `make deploy ENV=prod`.

Voltar uma versão **depois** que a migration rodou não é seguro: restaure o dump
do passo 3 com o `restore.sh` e só então volte o `N8N_VERSION`.

Releases: <https://github.com/n8n-io/n8n/releases>. Use só versões sem sufixo
(`2.38.7`, não `next`/`nightly`).

## 5. Backups e restore

Duas camadas, independentes:

| Camada                 | O que é                                          | Onde                                    | Retenção          |
| ---------------------- | ------------------------------------------------ | --------------------------------------- | ----------------- |
| Snapshot do disco      | Imagem inteira da VM, 06:00 UTC                  | GCP › Compute › Snapshots               | prod 14d / dev 7d |
| Dump diário (cron 03:30) | `pg_dump` + export de workflows e credenciais | `/opt/n8n/backups` na VM                | prod 14d / dev 7d |

```bash
make backup  ENV=prod                        # roda o dump agora
make backups ENV=prod                        # lista
make fetch-backup ENV=prod FILE=n8n-35-20260914-033000.dump   # baixa para ./backups/
```

**Restore do banco**, na VM (`make ssh ENV=prod`):

```bash
sudo /opt/n8n/scripts/restore.sh /opt/n8n/backups/n8n-35-20260914-033000.dump
```

Para o n8n, recria o banco, restaura e sobe de novo. Pede confirmação digitando
o host. A encryption key da VM precisa ser a mesma que gerou o dump.

**Restore de desastre** (VM perdida): crie uma VM nova a partir do snapshot
mais recente, ajuste `carregar_env` em [scripts/lib.sh](scripts/lib.sh) se o
nome/zona mudarem, e rode `make deploy`. Os volumes Docker estão no disco, então
tudo volta como estava.

**Copiar dumps para um bucket** (opcional): a SA padrão das VMs só tem scope de
_leitura_ no Storage. Para habilitar escrita é preciso parar a VM e rodar
`gcloud compute instances set-service-account n8n-prod --zone us-central1-a --scopes storage-rw,logging-write,monitoring-write`,
criar o bucket e preencher `BACKUP_BUCKET` no env file. O `backup.sh` já faz a
cópia quando a variável está definida.

## 6. Levar workflows de dev para prod

O backup diário já gera `*-workflows.json` (portável) e `*-credentials.json`
(criptografado com a chave de dev, portanto **não** importável em prod). Para
promover:

```bash
make backup ENV=dev && make backups ENV=dev
make fetch-backup ENV=dev FILE=n8n-136-<data>-workflows.json
# na VM de prod:
make ssh ENV=prod
sudo docker cp ~/n8n-136-<data>-workflows.json n8n-main:/tmp/wf.json
sudo docker compose -f /opt/n8n/docker-compose.yml exec n8n n8n import:workflow --input=/tmp/wf.json
```

As credenciais precisam ser recriadas em prod pela UI (ou via export com
`--decrypted` em dev, tratado como material sensível). Para algo mais elaborado
o n8n oferece _Source Control_ com Git, mas é recurso do plano Enterprise.

## 7. Domínio próprio

Hoje os hosts são `<ip>.sslip.io`, que resolve para o próprio IP (por isso o IP
é estático). Para usar um domínio da empresa:

1. Crie um registro `A` (ex.: `n8n.somalabs.com.br → 35.224.228.68`).
2. Troque `N8N_HOST` em `envs/prod.env`.
3. `make deploy ENV=prod`. O Caddy emite o certificado novo sozinho.

Webhooks já registrados em serviços externos apontam para o host antigo e
precisam ser reativados (desativar/ativar o workflow).

## 8. Estrutura do repositório

```
docker-compose.yml        stack (caddy, postgres, redis*, n8n, n8n-worker*)  *profile "queue"
caddy/Caddyfile           proxy + TLS
envs/prod.env, dev.env    config não sensível por ambiente (versionada)
scripts/lib.sh            projeto, mapa env→VM, helpers de ssh
scripts/gcp-setup.sh      tags, IP estático, disco, snapshot, APIs
scripts/secrets.sh        Secret Manager: ensure | render | set
scripts/deploy.sh         renderiza .env, copia, compose up, healthcheck
scripts/ops.sh            status, logs, ssh, restart, backup, fetch-backup, down
scripts/vm/bootstrap.sh   roda na VM: docker, cron, logs, updates
scripts/vm/backup.sh      roda na VM (cron): pg_dump + exports + retenção
scripts/vm/restore.sh     roda na VM: restaura um dump
.github/workflows/        deploy manual pelo GitHub (opcional, ver comentários)
Makefile                  atalhos; exige ENV=prod|dev
local-files/              montado em /files no n8n (nós Read/Write Files)
```

Na VM, `/opt/n8n` espelha isso: `docker-compose.yml`, `caddy/`, `scripts/`,
`.env` (600, root), `backups/`, `local-files/`.

## 9. Decisões e detalhes

- **Um compose, dois envs.** Prod liga o profile `queue` (`COMPOSE_PROFILES=queue`)
  e `EXECUTIONS_MODE=queue`; dev não. Evita dois arquivos quase iguais divergindo.
- **Secrets fora do git e fora da VM até o deploy.** O `deploy.sh` lê do Secret
  Manager com _sua_ credencial e grava o `.env` na VM com permissão 600. A SA da
  VM não precisa de acesso ao Secret Manager (e não tem).
- **Caddy em vez de nginx + certbot.** TLS automático com renovação, zero cron,
  websocket sem configuração.
- **Postgres em container com volume no disco.** Simples e coberto pelo
  snapshot. Se o volume de execuções crescer muito, o próximo passo é Cloud SQL
  (`DB_POSTGRESDB_HOST` aponta para fora e o serviço `postgres` sai do compose).
- **`N8N_RUNNERS_ENABLED=true`, `N8N_BLOCK_ENV_ACCESS_IN_NODE=true`.** Nós Code
  rodam isolados e não leem as variáveis de ambiente do container (onde estão
  a senha do banco e a encryption key).
- **Pruning de execuções.** Prod guarda 14 dias/50 k; dev 3 dias/10 k. Sem isso
  o banco só cresce.
- **`N8N_DIAGNOSTICS_ENABLED=false`.** Sem telemetria para a n8n GmbH.
- **Firewall.** As regras existentes na `soma-network` liberam 22, 80 e 443 para
  `0.0.0.0/0`. O n8n tem autenticação própria, mas para dev vale restringir 443
  aos IPs do escritório/VPN: crie uma regra com `--target-tags=https-server`
  e `--source-ranges` fechados, e remova a tag `https-server` da regra aberta.
- **Logs.** `json-file` com 20 MB × 5 por container (`/etc/docker/daemon.json`);
  o Ops Agent já está na VM (`enable-osconfig`) se quiser mandar para o Cloud Logging.

## 10. Problemas conhecidos

- **`healthz` não responde no primeiro deploy.** Quase sempre é o Caddy ainda
  emitindo o certificado, ou a tag `https-server` faltando (rode `make setup-gcp`).
  `make logs ENV=x SVC=caddy` mostra o erro do ACME se houver.
- **Let's Encrypt recusou (rate limit).** Emissões repetidas para o mesmo host
  em pouco tempo (5 por semana). Espere ou troque o host.
- **`permission denied` no docker sem sudo dentro da VM.** O bootstrap adiciona
  seu usuário ao grupo `docker`, mas só vale a partir do próximo login. Os
  scripts usam `sudo` justamente para não depender disso.
- **Disco não cresceu depois do `setup-gcp`.** Rode `make bootstrap` de novo (o
  passo de `growpart`/`resize2fs` é idempotente) ou reinicie a VM.
- **Worker em `unhealthy` logo após subir.** O worker espera o main ficar
  saudável; nos primeiros ~60 s é normal. Se persistir, veja se o redis está de pé.
