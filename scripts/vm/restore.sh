#!/usr/bin/env bash
# Roda NA VM: restaura um pg_dump gerado pelo backup.sh.
#   sudo /opt/n8n/scripts/restore.sh /opt/n8n/backups/n8n-...-20260914-033000.dump
#
# Para o n8n (e workers), recria o banco, restaura, sobe de novo. O volume
# n8n_data (encryption key em config, binários) não é tocado — a chave precisa
# ser a MESMA que criptografou as credenciais no dump.

set -euo pipefail
DUMP="${1:-}"
[ -f "$DUMP" ] || { echo "uso: $0 <arquivo .dump>"; exit 1; }
cd /opt/n8n
set -a; source ./.env; set +a
DC="docker compose"
USER_="${POSTGRES_USER:-n8n}"; DB="${POSTGRES_DB:-n8n}"

echo "Vai APAGAR o banco '${DB}' de ${N8N_HOST} e restaurar ${DUMP}."
read -rp "Digite o nome do host para confirmar: " conf
[ "$conf" = "$N8N_HOST" ] || { echo "abortado"; exit 1; }

echo "==> Parando n8n"
$DC stop n8n n8n-worker 2>/dev/null || $DC stop n8n

echo "==> Recriando banco"
$DC exec -T postgres psql -U "$USER_" -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB}' AND pid<>pg_backend_pid();" >/dev/null
$DC exec -T postgres psql -U "$USER_" -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${DB}\";"
$DC exec -T postgres psql -U "$USER_" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${DB}\" OWNER \"${USER_}\";"

echo "==> Restaurando"
$DC exec -T postgres pg_restore -U "$USER_" -d "$DB" --no-owner --no-privileges < "$DUMP"

echo "==> Subindo n8n"
$DC up -d
$DC ps
echo "ok"
