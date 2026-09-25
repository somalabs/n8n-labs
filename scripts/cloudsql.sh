#!/usr/bin/env bash
# Database e usuário do n8n no Cloud SQL (instância CLOUDSQL_INSTANCE, ver lib.sh).
# Roda da SUA máquina, pela API do Cloud SQL — não precisa de acesso à VPC.
#
#   ./scripts/cloudsql.sh prod ensure    # cria database + usuário se faltarem
#   ./scripts/cloudsql.sh prod info      # IP privado, versão, databases, usuários
#
# Uma instância só atende dev e prod: cada ambiente tem POSTGRES_DB e
# POSTGRES_USER próprios (envs/<env>.env). O `ensure` roda em todo deploy e,
# como o secrets.sh, NUNCA altera o que já existe: o usuário nasce com a senha
# que está no Secret Manager (n8n-<env>-postgres-password) e só. Se rotacionar
# o secret depois, aplique no Cloud SQL pelo console (instância n8n › Users)
# ou com `gcloud sql users set-password`, e então `make deploy`.
#
# Usuários criados pela API entram no role cloudsqlsuperuser, então o n8n
# consegue criar as tabelas sem GRANT manual.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud
ACAO="${2:-ensure}"

for v in POSTGRES_HOST POSTGRES_DB POSTGRES_USER; do
  [ -n "${!v:-}" ] || die "preencha ${v} em envs/${ENV_NAME}.env"
done

SQL=(--instance="$CLOUDSQL_INSTANCE" --project="$PROJECT")

instancia_ip() {
  gcloud sql instances describe "$CLOUDSQL_INSTANCE" --project="$PROJECT" \
    --format='value(ipAddresses.filter("type:PRIVATE").extract(ipAddress).flatten())' 2>/dev/null
}

case "$ACAO" in
  ensure)
    IP="$(instancia_ip)" || true
    [ -n "$IP" ] || die "instância Cloud SQL '${CLOUDSQL_INSTANCE}' não encontrada em ${PROJECT} (ou sem IP privado)"
    [ "$IP" = "$POSTGRES_HOST" ] || warn "envs/${ENV_NAME}.env tem POSTGRES_HOST=${POSTGRES_HOST}, mas o IP privado da instância é ${IP}"

    if gcloud sql databases describe "$POSTGRES_DB" "${SQL[@]}" >/dev/null 2>&1; then
      echo "  ok      database ${POSTGRES_DB}"
    else
      gcloud sql databases create "$POSTGRES_DB" "${SQL[@]}" --quiet >/dev/null
      echo "  criado  database ${POSTGRES_DB}"
    fi

    if gcloud sql users list "${SQL[@]}" --format='value(name)' | grep -qx "$POSTGRES_USER"; then
      echo "  ok      usuário ${POSTGRES_USER}"
    else
      SENHA="$("${ROOT_DIR}/scripts/secrets.sh" "$ENV_NAME" render | sed -n 's/^POSTGRES_PASSWORD=//p')"
      [ -n "$SENHA" ] || die "secret $(secret_id postgres-password) vazio; rode: make secrets ENV=${ENV_NAME}"
      gcloud sql users create "$POSTGRES_USER" "${SQL[@]}" --password="$SENHA" --quiet >/dev/null
      echo "  criado  usuário ${POSTGRES_USER} (senha = secret $(secret_id postgres-password))"
    fi
    ;;
  info)
    gcloud sql instances describe "$CLOUDSQL_INSTANCE" --project="$PROJECT" \
      --format='table(name,databaseVersion,region,settings.tier,ipAddresses[].ipAddress,settings.ipConfiguration.sslMode)'
    echo; echo "databases:"; gcloud sql databases list "${SQL[@]}" --format='value(name)' | sed 's/^/  /'
    echo; echo "usuários:";  gcloud sql users list "${SQL[@]}" --format='value(name)' | sed 's/^/  /'
    echo; echo "este ambiente (${ENV_NAME}): ${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT:-5432}/${POSTGRES_DB}"
    ;;
  *) die "ação desconhecida: ${ACAO} (ensure|info)" ;;
esac
