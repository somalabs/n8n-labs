#!/usr/bin/env bash
# Roda NA VM: psql interativo no Cloud SQL deste ambiente (`make psql ENV=...`).
set -euo pipefail
source "$(dirname "$0")/lib-pg.sh"
echo "conectando em ${POSTGRES_USER}@${POSTGRES_HOST}/${POSTGRES_DB} (\\q para sair)"
pg_tty psql "$@"
