# Atalhos. Sempre com ENV=prod ou ENV=dev.
#
#   make setup-gcp ENV=prod    # tags, IP estático, disco, snapshot (uma vez)
#   make secrets   ENV=prod    # cria secrets no Secret Manager (uma vez)
#   make bootstrap ENV=prod    # docker + cron na VM (uma vez)
#   make deploy    ENV=prod    # toda vez que mudar envs/prod.env, versão ou compose
#   make status / logs / ssh / backup / backups / restart ENV=prod

ENV ?=
SVC ?=
FILE ?=

ifeq ($(ENV),)
$(error informe ENV=prod ou ENV=dev)
endif

.PHONY: setup-gcp secrets bootstrap deploy deploy-config status logs ssh restart down backup backups fetch-backup validate

setup-gcp:
	./scripts/gcp-setup.sh $(ENV)

secrets:
	./scripts/secrets.sh $(ENV) ensure

bootstrap:
	gcloud compute ssh $$(./scripts/print-vm.sh $(ENV) name) --zone=$$(./scripts/print-vm.sh $(ENV) zone) --project=soma-ai-hub --quiet -- 'sudo bash -s' < scripts/vm/bootstrap.sh

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

# Valida o compose com um .env de exemplo (sem tocar em GCP).
validate:
	@tmp=$$(mktemp); grep -vE '^\s*(#|$$)' envs/$(ENV).env > $$tmp; \
	  printf 'ACME_EMAIL=x@example.com\nPOSTGRES_PASSWORD=x\nN8N_ENCRYPTION_KEY=x\nN8N_JWT_SECRET=x\n' >> $$tmp; \
	  docker compose --env-file $$tmp config -q && echo "compose ok ($(ENV))"; rm -f $$tmp
