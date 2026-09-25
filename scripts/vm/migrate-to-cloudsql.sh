#!/usr/bin/env bash
# Roda NA VM, UMA vez, depois do primeiro `make deploy` com o compose novo
# (sem o serviço postgres): leva os dados do postgres que rodava em container
# na VM para o Cloud SQL deste ambiente.
#   sudo /opt/n8n/scripts/migrate-to-cloudsql.sh
#
#   1. sobe um postgres descartável em cima do volume antigo (n8n_postgres_data)
#   2. pg_dump → /opt/n8n/backups/pre-cloudsql-<data>.dump (fica guardado)
#   3. restore.sh <dump> --yes  (para o n8n, zera o schema no Cloud SQL, restaura, sobe)
#
# O volume antigo NÃO é apagado. Quando tiver certeza de que está tudo certo:
#   sudo docker volume rm n8n_postgres_data
#
# LEGACY_*: como era o postgres antigo (defaults do compose anterior).

set -euo pipefail
source "$(dirname "$0")/lib-pg.sh"
LEGACY_VOLUME="${LEGACY_VOLUME:-n8n_postgres_data}"
LEGACY_VERSION="${LEGACY_VERSION:-16}"
LEGACY_USER="${LEGACY_USER:-n8n}"
LEGACY_DB="${LEGACY_DB:-n8n}"
TMP_CT="n8n-pg-legacy"

docker volume inspect "$LEGACY_VOLUME" >/dev/null 2>&1 \
  || { echo "volume ${LEGACY_VOLUME} não existe — nada a migrar (ou já foi removido)"; exit 1; }

echo "Vai copiar ${LEGACY_DB} do volume ${LEGACY_VOLUME} (postgres ${LEGACY_VERSION}) para"
echo "${POSTGRES_DB}@${POSTGRES_HOST} (Cloud SQL), APAGANDO o que houver lá."
read -rp "Digite o nome do host (${N8N_HOST}) para confirmar: " conf
[ "$conf" = "$N8N_HOST" ] || { echo "abortado"; exit 1; }

echo "==> Parando o que ainda usa o volume antigo"
docker rm -f n8n-postgres "$TMP_CT" >/dev/null 2>&1 || true
trap 'docker rm -f "$TMP_CT" >/dev/null 2>&1 || true' EXIT

echo "==> Subindo postgres ${LEGACY_VERSION} descartável sobre ${LEGACY_VOLUME}"
docker run -d --name "$TMP_CT" -v "${LEGACY_VOLUME}:/var/lib/postgresql/data" \
  "postgres:${LEGACY_VERSION}-alpine" >/dev/null
for i in $(seq 1 30); do
  docker exec "$TMP_CT" pg_isready -U "$LEGACY_USER" -d "$LEGACY_DB" >/dev/null 2>&1 && break
  [ "$i" = 30 ] && { echo "postgres antigo não subiu"; docker logs "$TMP_CT" | tail -20; exit 1; }
  sleep 1
done

DUMP="backups/pre-cloudsql-$(date +%Y%m%d-%H%M%S).dump"
echo "==> pg_dump → ${DUMP}"
# Dentro do container o socket unix é trust: não precisa da senha antiga.
docker exec "$TMP_CT" pg_dump -U "$LEGACY_USER" -d "$LEGACY_DB" -Fc --no-owner --no-privileges > "$DUMP"
chmod 600 "$DUMP"; ls -lh "$DUMP"
docker rm -f "$TMP_CT" >/dev/null

echo "==> Restaurando no Cloud SQL"
"$(dirname "$0")/restore.sh" "$DUMP" --yes

echo
echo "Migração concluída. Confira o n8n em http://${N8N_HOST}/ e, quando estiver satisfeito:"
echo "  sudo docker volume rm ${LEGACY_VOLUME}"
