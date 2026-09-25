#!/usr/bin/env bash
# Roda NA VM (cron diário 03:30 ou `make backup ENV=...`). Gera em /opt/n8n/backups:
#   n8n-<env-host>-<data>.dump          pg_dump custom format do Cloud SQL (restore.sh)
#   n8n-<env-host>-<data>-workflows.json   export de workflows (portável)
#   n8n-<env-host>-<data>-credentials.json export de credenciais (criptografado
#                                          com a N8N_ENCRYPTION_KEY — sem ela é inútil)
# Apaga o que for mais velho que BACKUP_RETENTION_DAYS. Se BACKUP_BUCKET estiver
# definido, copia para gs://BACKUP_BUCKET/<host>/ (a SA da VM precisa de scope
# de escrita no Storage; ver README).
#
# O Cloud SQL tem backup automático próprio (console › instância n8n › Backups);
# este dump cobre "quero voltar SÓ o banco deste ambiente" ou "quero levar os
# dados para outro lugar" sem depender do restore de instância inteira.

set -euo pipefail
source "$(dirname "$0")/lib-pg.sh"
DC="docker compose"
STAMP="$(date +%Y%m%d-%H%M%S)"
PREFIX="backups/n8n-${N8N_HOST%%.*}-${STAMP}"
RET="${BACKUP_RETENTION_DAYS:-14}"

echo "[$(date -Is)] backup ${POSTGRES_DB}@${POSTGRES_HOST} → ${PREFIX}*"
pg pg_dump -Fc --no-owner --no-privileges > "${PREFIX}.dump"
$DC exec -T n8n n8n export:workflow --all --pretty > "${PREFIX}-workflows.json" 2>/dev/null \
  || echo "  (export de workflows falhou ou não há workflows)"
$DC exec -T n8n n8n export:credentials --all --pretty > "${PREFIX}-credentials.json" 2>/dev/null \
  || echo "  (export de credenciais falhou ou não há credenciais)"
chmod 600 "${PREFIX}"*
ls -lh "${PREFIX}"*

if [ -n "${BACKUP_BUCKET:-}" ]; then
  if command -v gcloud >/dev/null 2>&1; then
    gcloud storage cp "${PREFIX}"* "gs://${BACKUP_BUCKET}/${N8N_HOST}/" --quiet \
      && echo "  copiado para gs://${BACKUP_BUCKET}/${N8N_HOST}/" \
      || echo "  falha ao copiar para o bucket (scope da SA? bucket existe?)"
  else
    echo "  BACKUP_BUCKET definido mas gcloud não está na VM"
  fi
fi

find backups -type f -mtime +"$RET" -name 'n8n-*' -print -delete | sed 's/^/  removido: /'
echo "[$(date -Is)] ok"
