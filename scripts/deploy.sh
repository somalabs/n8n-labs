#!/usr/bin/env bash
# Deploy (e redeploy) do n8n em uma VM. Roda da SUA máquina:
#   1. garante que os secrets existem no Secret Manager
#   2. renderiza o .env = envs/<env>.env + secrets
#   3. copia compose, Caddyfile, scripts de VM e .env para /opt/n8n
#   4. docker compose pull + up -d  (zero mudança se nada mudou)
#   5. espera o /healthz responder via HTTPS
#
#   ./scripts/deploy.sh prod
#   ./scripts/deploy.sh dev --no-pull      # não baixa imagens (rede lenta / só mudou config)
#
# Pré-requisitos por VM (uma vez só): gcp-setup.sh e bootstrap (make bootstrap).

set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud
PULL=1; [ "${2:-}" = "--no-pull" ] && PULL=0

[ -n "${ACME_EMAIL:-}" ] || die "preencha ACME_EMAIL em envs/${ENV_NAME}.env (contato do Let's Encrypt)"
[ -n "${N8N_HOST:-}" ]   || die "preencha N8N_HOST em envs/${ENV_NAME}.env"

log "Secrets (${ENV_NAME})"
"${ROOT_DIR}/scripts/secrets.sh" "$ENV_NAME" ensure

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
cp -R "${ROOT_DIR}/caddy" "$STAGE/"
cp -R "${ROOT_DIR}/scripts/vm" "${STAGE}/scripts"
cp "${TMP}/.env" "$STAGE/.env"
# Copia para o home e move com sudo: /opt/n8n é do root.
vm_ssh "rm -rf ~/n8n-stage && mkdir -p ~/n8n-stage"
vm_scp --recurse "${STAGE}/." "${VM}:~/n8n-stage/"
vm_ssh "sudo mkdir -p ${REMOTE_DIR}/local-files ${REMOTE_DIR}/backups \
  && sudo cp -R ~/n8n-stage/. ${REMOTE_DIR}/ \
  && sudo chown -R root:root ${REMOTE_DIR}/docker-compose.yml ${REMOTE_DIR}/caddy ${REMOTE_DIR}/scripts ${REMOTE_DIR}/.env \
  && sudo chmod 600 ${REMOTE_DIR}/.env && sudo chmod +x ${REMOTE_DIR}/scripts/*.sh \
  && sudo chown -R 1000:1000 ${REMOTE_DIR}/local-files \
  && rm -rf ~/n8n-stage"

log "Subindo containers"
if [ "$PULL" = 1 ]; then
  vm_ssh "cd ${REMOTE_DIR} && sudo docker compose pull --quiet"
fi
vm_ssh "cd ${REMOTE_DIR} && sudo docker compose up -d --remove-orphans && sudo docker compose ps"

log "Aguardando https://${N8N_HOST}/healthz"
for i in $(seq 1 30); do
  if curl -fsS --max-time 5 "https://${N8N_HOST}/healthz" >/dev/null 2>&1; then
    echo "  saudável após ~$((i*5))s"
    echo
    log "n8n ${ENV_NAME} em https://${N8N_HOST}/"
    exit 0
  fi
  sleep 5
done
warn "healthz não respondeu em 150s. Veja: make logs ENV=${ENV_NAME}"
warn "(no primeiro deploy o Let's Encrypt pode levar mais tempo; o Caddy tenta de novo sozinho)"
exit 1
