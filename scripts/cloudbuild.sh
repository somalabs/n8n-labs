#!/usr/bin/env bash
# Deploy pelo Cloud Build (cloudbuild.yaml) — o mesmo deploy.sh, rodando no GCP.
# Roda da SUA máquina, com gcloud autenticado.
#
#   ./scripts/cloudbuild.sh prod setup    # papéis da SA vm-deploy + secret do env file + trigger (idempotente)
#   ./scripts/cloudbuild.sh prod run      # sincroniza envs/prod.env → secret, dispara o trigger e segue o log
#   ./scripts/cloudbuild.sh prod builds   # últimos builds deste ambiente
#   ./scripts/cloudbuild.sh prod log [id] # log de um build (padrão: o mais recente)
#
# Trigger: n8n-deploy-<env>, manual, no repo somalabs/n8n-labs (conexão
# github-somalabs, 2ª geração, região us-central1), branch main, com
# _ENV=<env>. Roda como a SA vm-deploy — a mesma que o GitHub Actions usava.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud
ACAO="${2:-run}"

TRIGGER="n8n-deploy-${ENV_NAME}"
BRANCH="${CLOUDBUILD_BRANCH:-main}"
CONNECTION="github-somalabs"
REPO_LINK="somalabs-n8n-labs"
REPO="projects/${PROJECT}/locations/${REGION}/connections/${CONNECTION}/repositories/${REPO_LINK}"
SA="vm-deploy@${PROJECT}.iam.gserviceaccount.com"
# O que a SA precisa para o deploy.sh rodar de dentro do Cloud Build:
SA_ROLES=(
  roles/compute.instanceAdmin.v1    # registra a chave ssh nos metadados
  roles/iam.serviceAccountUser
  roles/iap.tunnelResourceAccessor  # túnel IAP para a porta 22
  roles/secretmanager.admin         # cria os secrets que faltarem
  roles/secretmanager.secretAccessor
  roles/cloudsql.admin              # cria o database do ambiente se faltar
  roles/logging.logWriter           # log do build (SA própria exige isto)
)
CB=(--project="$PROJECT" --region="$REGION")

case "$ACAO" in
  setup)
    log "APIs (cloudbuild)"
    gcloud services enable cloudbuild.googleapis.com --project="$PROJECT" --quiet

    log "Papéis da SA ${SA}"
    gcloud iam service-accounts describe "$SA" --project="$PROJECT" >/dev/null \
      || die "SA ${SA} não existe; crie com: gcloud iam service-accounts create vm-deploy --project=${PROJECT}"
    for role in "${SA_ROLES[@]}"; do
      gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:${SA}" --role="$role" \
        --condition=None --quiet >/dev/null
      echo "  ok      ${role}"
    done

    log "Repositório ${REPO_LINK} na conexão ${CONNECTION}"
    gcloud builds repositories describe "$REPO_LINK" --connection="$CONNECTION" "${CB[@]}" --format='value(remoteUri)' \
      || die "repo não está vinculado à conexão ${CONNECTION}; vincule em Cloud Build › Repositories (2ª geração)"

    log "Secret do env file"
    "${ROOT_DIR}/scripts/secrets.sh" "$ENV_NAME" env-file

    log "Trigger ${TRIGGER} (manual, branch ${BRANCH}, _ENV=${ENV_NAME})"
    if gcloud builds triggers describe "$TRIGGER" "${CB[@]}" >/dev/null 2>&1; then
      gcloud builds triggers delete "$TRIGGER" "${CB[@]}" --quiet
      echo "  recriando ${TRIGGER}"
    fi
    gcloud builds triggers create manual "$TRIGGER" "${CB[@]}" \
      --repository="$REPO" --branch="$BRANCH" \
      --build-config=cloudbuild.yaml \
      --substitutions="_ENV=${ENV_NAME}" \
      --service-account="projects/${PROJECT}/serviceAccounts/${SA}" \
      --description="n8n ${ENV_NAME}: scripts/deploy.sh via IAP (manual)" \
      --quiet >/dev/null
    echo "  criado  ${TRIGGER}"
    echo
    echo "Pronto: make cloudbuild-deploy ENV=${ENV_NAME}"
    ;;

  run)
    "${ROOT_DIR}/scripts/secrets.sh" "$ENV_NAME" env-file
    log "Disparando ${TRIGGER} (branch ${BRANCH})"
    BUILD_ID="$(gcloud builds triggers run "$TRIGGER" "${CB[@]}" --branch="$BRANCH" \
      --format='value(metadata.build.id)')"
    [ -n "$BUILD_ID" ] || die "não consegui disparar ${TRIGGER}; rode: $0 ${ENV_NAME} setup"
    echo "  build ${BUILD_ID}"
    echo "  https://console.cloud.google.com/cloud-build/builds;region=${REGION}/${BUILD_ID}?project=${PROJECT}"
    gcloud builds log "$BUILD_ID" "${CB[@]}" --stream
    STATUS="$(gcloud builds describe "$BUILD_ID" "${CB[@]}" --format='value(status)')"
    [ "$STATUS" = SUCCESS ] || die "build terminou com status ${STATUS}"
    ;;

  builds)
    gcloud builds list "${CB[@]}" --filter="substitutions._ENV=${ENV_NAME}" --limit=10 \
      --format='table(id,status,createTime.date(tz=LOCAL),duration(),substitutions._ENV)'
    ;;

  log)
    BUILD_ID="${3:-}"
    [ -n "$BUILD_ID" ] || BUILD_ID="$(gcloud builds list "${CB[@]}" --filter="substitutions._ENV=${ENV_NAME}" --limit=1 --format='value(id)')"
    [ -n "$BUILD_ID" ] || die "nenhum build de ${ENV_NAME} ainda"
    gcloud builds log "$BUILD_ID" "${CB[@]}"
    ;;

  *) die "ação desconhecida: ${ACAO} (setup|run|builds|log)" ;;
esac
