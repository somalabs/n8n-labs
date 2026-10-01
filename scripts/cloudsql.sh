#!/usr/bin/env bash
# Database do n8n no Cloud SQL (instância CLOUDSQL_INSTANCE, ver lib.sh).
# Roda da SUA máquina, pela API do Cloud SQL — não precisa de acesso à VPC.
#
#   ./scripts/cloudsql.sh prod ensure    # cria o database se faltar; confere que o usuário existe
#   ./scripts/cloudsql.sh prod info      # IP privado, versão, databases, usuários
#
# Uma instância só atende dev e prod, cada um no seu POSTGRES_DB. O usuário
# (POSTGRES_USER) tem que JÁ EXISTIR na instância: este script nunca cria nem
# altera usuário/senha. A senha dele vai no secret n8n-<env>-postgres-password
# (./scripts/secrets.sh <env> set POSTGRES_PASSWORD).

set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud
ACAO="${2:-ensure}"

for v in POSTGRES_HOST POSTGRES_DB POSTGRES_USER; do
  [ -n "${!v:-}" ] || die "preencha ${v} em envs/${ENV_NAME}.env"
done

SQL=(--instance="$CLOUDSQL_INSTANCE" --project="$PROJECT")

# Deixa o erro do gcloud aparecer: "não encontrada" e "sem permissão" são
# problemas diferentes (quem roda precisa de roles/cloudsql.admin).
instancia_ip() {
  gcloud sql instances describe "$CLOUDSQL_INSTANCE" --project="$PROJECT" \
    --format='value(ipAddresses.filter("type:PRIVATE").extract(ipAddress).flatten())'
}

case "$ACAO" in
  ensure)
    IP="$(instancia_ip)" || die "não consegui consultar a instância Cloud SQL '${CLOUDSQL_INSTANCE}' em ${PROJECT} (veja o erro acima)"
    [ -n "$IP" ] || die "instância Cloud SQL '${CLOUDSQL_INSTANCE}' existe mas não tem IP privado"
    [ "$IP" = "$POSTGRES_HOST" ] || warn "envs/${ENV_NAME}.env tem POSTGRES_HOST=${POSTGRES_HOST}, mas o IP privado da instância é ${IP}"

    if gcloud sql users list "${SQL[@]}" --format='value(name)' | grep -qx "$POSTGRES_USER"; then
      echo "  ok      usuário ${POSTGRES_USER} (existente)"
    else
      die "usuário ${POSTGRES_USER} não existe na instância ${CLOUDSQL_INSTANCE}. Use um usuário existente em POSTGRES_USER (envs/${ENV_NAME}.env); veja: $0 ${ENV_NAME} info"
    fi

    if gcloud sql databases describe "$POSTGRES_DB" "${SQL[@]}" >/dev/null 2>&1; then
      echo "  ok      database ${POSTGRES_DB}"
    else
      gcloud sql databases create "$POSTGRES_DB" "${SQL[@]}" --quiet >/dev/null
      echo "  criado  database ${POSTGRES_DB}"
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
