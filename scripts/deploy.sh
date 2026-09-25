#!/usr/bin/env bash
# Deploy (e redeploy) do n8n em uma VM. Roda da SUA máquina:
#   1. garante que os secrets existem no Secret Manager
#   2. garante database + usuário deste ambiente no Cloud SQL
#   3. renderiza o .env = envs/<env>.env + secrets
#   4. copia compose, scripts de VM e .env para /opt/n8n
#   5. docker compose pull + up -d  (zero mudança se nada mudou)
#   6. espera o /healthz responder na porta publicada
#
#   ./scripts/deploy.sh prod
#   ./scripts/deploy.sh dev --no-pull      # não baixa imagens (rede lenta / só mudou config)
#   SSH_VIA_IAP=1 ./scripts/deploy.sh dev  # fora da VPN: ssh pelo IAP (ver lib.sh)
#
# Pré-requisitos por VM (uma vez só): gcp-setup.sh e bootstrap (make bootstrap).

set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud
PULL=1; [ "${2:-}" = "--no-pull" ] && PULL=0

[ -n "${N8N_HOST:-}" ] || die "preencha N8N_HOST em envs/${ENV_NAME}.env"
for v in POSTGRES_HOST POSTGRES_DB POSTGRES_USER; do
  [ -n "${!v:-}" ] || die "preencha ${v} em envs/${ENV_NAME}.env (Cloud SQL)"
done
PORTA="${N8N_PUBLISH_PORT:-80}"

log "Secrets (${ENV_NAME})"
"${ROOT_DIR}/scripts/secrets.sh" "$ENV_NAME" ensure

log "Cloud SQL (${CLOUDSQL_INSTANCE}): database ${POSTGRES_DB}, usuário ${POSTGRES_USER}"
"${ROOT_DIR}/scripts/cloudsql.sh" "$ENV_NAME" ensure

log "Renderizando .env"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  echo "# GERADO por scripts/deploy.sh em $(date -u +%FT%TZ) — não edite na VM; edite envs/${ENV_NAME}.env"
  grep -vE '^\s*(#|$)' "$ENV_FILE"
  echo
  "${ROOT_DIR}/scripts/secrets.sh" "$ENV_NAME" render
} > "${TMP}/.env"
chmod 600 "${TMP}/.env"

log "Validando compose localmente"
if command -v docker >/dev/null 2>&1; then
  (cd "$ROOT_DIR" && docker compose --env-file "${TMP}/.env" config -q) || die "docker-compose.yml inválido"
else
  warn "docker não está instalado aqui; pulando validação local"
fi

log "Copiando arquivos para ${VM}:${REMOTE_DIR}"
STAGE="${TMP}/stage"; mkdir -p "$STAGE"
cp "${ROOT_DIR}/docker-compose.yml" "$STAGE/"
cp -R "${ROOT_DIR}/scripts/vm" "${STAGE}/scripts"
cp "${TMP}/.env" "$STAGE/.env"
# Copia para o home e move com sudo: /opt/n8n é do root.
vm_ssh "rm -rf ~/n8n-stage && mkdir -p ~/n8n-stage"
vm_scp --recurse "${STAGE}/." "${VM}:~/n8n-stage/"
vm_ssh "sudo mkdir -p ${REMOTE_DIR}/local-files ${REMOTE_DIR}/backups \
  && sudo cp -R ~/n8n-stage/. ${REMOTE_DIR}/ \
  && sudo rm -rf ${REMOTE_DIR}/caddy \
  && sudo chown -R root:root ${REMOTE_DIR}/docker-compose.yml ${REMOTE_DIR}/scripts ${REMOTE_DIR}/.env \
  && sudo chmod 600 ${REMOTE_DIR}/.env && sudo chmod +x ${REMOTE_DIR}/scripts/*.sh \
  && sudo chown -R 1000:1000 ${REMOTE_DIR}/local-files \
  && rm -rf ~/n8n-stage"

log "Subindo containers"
if [ "$PULL" = 1 ]; then
  vm_ssh "cd ${REMOTE_DIR} && sudo docker compose pull --quiet"
fi
# --remove-orphans derruba containers de serviços que saíram do compose
# (postgres e caddy da versão anterior). O volume n8n_postgres_data fica —
# é dele que o migrate-to-cloudsql.sh lê, se ainda houver dados a migrar.
vm_ssh "cd ${REMOTE_DIR} && sudo docker compose up -d --remove-orphans && sudo docker compose ps"

# O healthz é testado DE DENTRO da VM (via ssh): o DNS aponta para o IP
# interno e o firewall só deixa a rede da empresa (VPN) chegar — de fora
# (GitHub Actions, casa) o curl direto nunca responde.
log "Aguardando http://127.0.0.1:${PORTA}/healthz (testado na VM)"
if vm_ssh 'bash -s' <<EOF
for i in \$(seq 1 30); do
  if curl -fsS --max-time 5 "http://127.0.0.1:${PORTA}/healthz" >/dev/null 2>&1; then
    echo "  saudável após ~\$((i*5))s"; exit 0
  fi
  sleep 5
done
exit 1
EOF
then
  echo
  URL="http://${N8N_HOST}/"; [ "$PORTA" = 80 ] || URL="http://${N8N_HOST}:${PORTA}/"
  log "n8n ${ENV_NAME} em ${URL} (acessível pela VPN)"
  exit 0
fi
warn "healthz não respondeu em 150s. Veja: make logs ENV=${ENV_NAME} SVC=n8n"
warn "(o n8n roda as migrations no Cloud SQL ao subir; se o banco não responde, confira POSTGRES_HOST e a senha)"
exit 1
