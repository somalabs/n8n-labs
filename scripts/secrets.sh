#!/usr/bin/env bash
# Secrets do n8n no Secret Manager, um conjunto por ambiente:
#   n8n-<env>-postgres-password, n8n-<env>-encryption-key, n8n-<env>-jwt-secret
#
#   ./scripts/secrets.sh prod ensure         # cria encryption-key e jwt-secret se faltarem (aleatórios);
#                                            # exige que postgres-password já exista
#   ./scripts/secrets.sh prod render         # imprime VAR=valor (usado pelo deploy)
#   ./scripts/secrets.sh prod set POSTGRES_PASSWORD   # nova versão, lê do stdin
#   ./scripts/secrets.sh prod env-file       # envs/prod.env → secret n8n-prod-env-file (para o Cloud Build;
#                                            # só cria versão nova se o conteúdo mudou)
#
# POSTGRES_PASSWORD é a senha de um usuário que JÁ EXISTE no Cloud SQL
# (POSTGRES_USER em envs/<env>.env) — nunca é gerada aqui; cadastre com `set`.
#
# `ensure` NUNCA sobrescreve um secret existente — em especial a encryption
# key: trocá-la inutiliza todas as credenciais salvas no n8n.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud
ACAO="${2:-ensure}"

gerar() { openssl rand -base64 48 | tr -d '\n=/+' | cut -c1-48; }

case "$ACAO" in
  ensure)
    for par in "${SECRET_VARS[@]}"; do
      var="${par%%:*}"; sid="$(secret_id "${par##*:}")"
      if gcloud secrets describe "$sid" --project="$PROJECT" >/dev/null 2>&1; then
        echo "  ok      ${sid}"
      elif [ "$var" = "POSTGRES_PASSWORD" ]; then
        die "falta ${sid}: cadastre a senha do usuário ${POSTGRES_USER:-<POSTGRES_USER>} do Cloud SQL com: $0 ${ENV_NAME} set POSTGRES_PASSWORD"
      else
        gcloud secrets create "$sid" --project="$PROJECT" --replication-policy=automatic --quiet
        printf '%s' "$(gerar)" | gcloud secrets versions add "$sid" --project="$PROJECT" --data-file=- --quiet >/dev/null
        echo "  criado  ${sid}  (${var})"
      fi
    done
    ;;
  render)
    for par in "${SECRET_VARS[@]}"; do
      var="${par%%:*}"; sid="$(secret_id "${par##*:}")"
      valor="$(gcloud secrets versions access latest --secret="$sid" --project="$PROJECT")" \
        || die "secret ${sid} não existe; rode: $0 ${ENV_NAME} ensure"
      printf '%s=%s\n' "$var" "$valor"
    done
    ;;
  set)
    var="${3:-}"; [ -n "$var" ] || die "uso: $0 ${ENV_NAME} set <VAR>"
    sid=""
    for par in "${SECRET_VARS[@]}"; do [ "${par%%:*}" = "$var" ] && sid="$(secret_id "${par##*:}")"; done
    [ -n "$sid" ] || die "variável desconhecida: ${var} (opções: ${SECRET_VARS[*]%%:*})"
    [ "$var" = "N8N_ENCRYPTION_KEY" ] && warn "trocar a encryption key inutiliza as credenciais já salvas no n8n"
    read -rsp "novo valor de ${var}: " valor; echo
    [ -n "$valor" ] || die "valor vazio"
    if ! gcloud secrets describe "$sid" --project="$PROJECT" >/dev/null 2>&1; then
      gcloud secrets create "$sid" --project="$PROJECT" --replication-policy=automatic --quiet
    fi
    printf '%s' "$valor" | gcloud secrets versions add "$sid" --project="$PROJECT" --data-file=- --quiet >/dev/null
    echo "  nova versão em ${sid}. Rode make deploy ENV=${ENV_NAME} para aplicar."
    ;;
  env-file)
    # O Cloud Build não tem o envs/<env>.env (fora do git); lê deste secret.
    # Seu arquivo local continua sendo a fonte da verdade — isto é uma cópia.
    sid="$(secret_id env-file)"
    if ! gcloud secrets describe "$sid" --project="$PROJECT" >/dev/null 2>&1; then
      gcloud secrets create "$sid" --project="$PROJECT" --replication-policy=automatic --quiet
    fi
    atual="$(gcloud secrets versions access latest --secret="$sid" --project="$PROJECT" 2>/dev/null || true)"
    if [ "$atual" = "$(cat "$ENV_FILE")" ]; then
      echo "  ok      ${sid} (igual a envs/${ENV_NAME}.env)"
    else
      gcloud secrets versions add "$sid" --project="$PROJECT" --data-file="$ENV_FILE" --quiet >/dev/null
      echo "  enviado ${sid} ← envs/${ENV_NAME}.env"
    fi
    ;;
  *) die "ação desconhecida: ${ACAO} (ensure|render|set|env-file)" ;;
esac
