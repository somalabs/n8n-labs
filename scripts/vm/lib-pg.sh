#!/usr/bin/env bash
# Carregado (source) pelos scripts da VM que falam com o Cloud SQL. Não tem
# psql/pg_dump instalado na VM: cada chamada roda um container descartável
# postgres:<POSTGRES_VERSION>-alpine já apontado para o banco deste ambiente
# (variáveis PG* vindas do .env). A instância exige TLS → PGSSLMODE=require.
#
#   pg pg_dump -Fc > x.dump            # stdin/stdout passam pelo container
#   pg psql -c "select 1"
#   pg_tty psql                        # interativo

cd /opt/n8n
set -a; source ./.env; set +a
for v in POSTGRES_HOST POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD; do
  [ -n "${!v:-}" ] || { echo "falta ${v} no /opt/n8n/.env — rode make deploy"; exit 1; }
done

PG_IMAGE="postgres:${POSTGRES_VERSION:-18}-alpine"
PG_ENV=(
  -e PGHOST="$POSTGRES_HOST" -e PGPORT="${POSTGRES_PORT:-5432}"
  -e PGDATABASE="$POSTGRES_DB" -e PGUSER="$POSTGRES_USER" -e PGPASSWORD="$POSTGRES_PASSWORD"
  -e PGSSLMODE=require
)
pg()     { docker run --rm -i  "${PG_ENV[@]}" "$PG_IMAGE" "$@"; }
pg_tty() { docker run --rm -it "${PG_ENV[@]}" "$PG_IMAGE" "$@"; }
