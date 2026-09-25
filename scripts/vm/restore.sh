#!/usr/bin/env bash
# Roda NA VM: restaura um pg_dump (backup.sh ou migrate-to-cloudsql.sh) no
# database deste ambiente no Cloud SQL.
#   sudo /opt/n8n/scripts/restore.sh /opt/n8n/backups/n8n-...-20260914-033000.dump
#   sudo /opt/n8n/scripts/restore.sh <dump> --yes     # sem prompt (usado pela migração)
#
# Para o n8n (e workers), zera o schema public do database (não dropa o
# database: ele pertence à instância compartilhada), restaura, sobe de novo.
# O volume n8n_data (encryption key em config, binários) não é tocado — a
# chave precisa ser a MESMA que criptografou as credenciais no dump.

set -euo pipefail
DUMP="${1:-}"
[ -f "$DUMP" ] || { echo "uso: $0 <arquivo .dump> [--yes]"; exit 1; }
source "$(dirname "$0")/lib-pg.sh"
DC="docker compose"

echo "Vai APAGAR o conteúdo de ${POSTGRES_DB} em ${POSTGRES_HOST} (${N8N_HOST}) e restaurar ${DUMP}."
if [ "${2:-}" != "--yes" ]; then
  read -rp "Digite o nome do host para confirmar: " conf
  [ "$conf" = "$N8N_HOST" ] || { echo "abortado"; exit 1; }
fi

echo "==> Parando n8n"
$DC stop n8n n8n-worker 2>/dev/null || $DC stop n8n

echo "==> Zerando schema public de ${POSTGRES_DB}"
pg psql -v ON_ERROR_STOP=1 -q -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid();" >/dev/null
pg psql -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

echo "==> Restaurando"
pg pg_restore -d "$POSTGRES_DB" --no-owner --no-privileges < "$DUMP"

echo "==> Subindo n8n"
$DC up -d
$DC ps
echo "ok"
