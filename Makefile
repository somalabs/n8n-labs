# Atalhos. Sempre com ENV=prod ou ENV=dev.
# Fora da VPN, prefixe com SSH_VIA_IAP=1 (ver scripts/lib.sh).
#
#   make setup-gcp ENV=prod    # APIs, disco, snapshot, checagem de DNS (uma vez)
#   make secrets   ENV=prod    # cria secrets no Secret Manager (uma vez)
#   make setup-db  ENV=prod    # database + usuário no Cloud SQL (o deploy também faz)
#   make bootstrap ENV=prod    # docker + cron na VM (uma vez)
#   make deploy    ENV=prod    # toda vez que mudar envs/prod.env, versão ou compose
#   make migrate-db ENV=dev    # postgres antigo da VM → Cloud SQL (uma vez, após o 1º deploy novo)
#   make status / logs / ssh / psql / backup / backups / restore / restart ENV=prod

ENV ?=
SVC ?=
FILE ?=

ifeq ($(ENV),)
$(error informe ENV=prod ou ENV=dev)
endif

.PHONY: setup-gcp secrets setup-db db-info bootstrap deploy deploy-config status logs ssh psql restart down backup backups fetch-backup restore migrate-db validate

setup-gcp:
	./scripts/gcp-setup.sh $(ENV)

secrets:
	./scripts/secrets.sh $(ENV) ensure

setup-db:
	./scripts/cloudsql.sh $(ENV) ensure

db-info:
	./scripts/cloudsql.sh $(ENV) info

bootstrap:
	./scripts/bootstrap.sh $(ENV)

deploy:
	./scripts/deploy.sh $(ENV)

# Só reaplica config/.env sem baixar imagem.
deploy-config:
	./scripts/deploy.sh $(ENV) --no-pull

status:
	./scripts/ops.sh $(ENV) status

logs:
	./scripts/ops.sh $(ENV) logs $(SVC)

ssh:
	./scripts/ops.sh $(ENV) ssh

psql:
	./scripts/ops.sh $(ENV) psql

restart:
	./scripts/ops.sh $(ENV) restart $(SVC)

down:
	./scripts/ops.sh $(ENV) down

backup:
	./scripts/ops.sh $(ENV) backup

backups:
	./scripts/ops.sh $(ENV) backups

fetch-backup:
	./scripts/ops.sh $(ENV) fetch-backup $(FILE)

restore:
	./scripts/ops.sh $(ENV) restore $(FILE)

migrate-db:
	./scripts/ops.sh $(ENV) migrate-db

# Valida o compose com um .env de exemplo (sem tocar em GCP).
validate:
	@tmp=$$(mktemp); grep -vE '^\s*(#|$$)' envs/$(ENV).env > $$tmp; \
	  printf 'POSTGRES_PASSWORD=x\nN8N_ENCRYPTION_KEY=x\nN8N_JWT_SECRET=x\n' >> $$tmp; \
	  docker compose --env-file $$tmp config -q && echo "compose ok ($(ENV))"; rm -f $$tmp
