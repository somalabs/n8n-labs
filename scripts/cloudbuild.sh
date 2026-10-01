#!/usr/bin/env bash
# Deploy pelo Cloud Build (cloudbuild.yaml) — o mesmo deploy.sh, rodando no GCP.
# Roda da SUA máquina, com gcloud autenticado.
#
#   ./scripts/cloudbuild.sh prod setup    # papéis da SA vm-deploy + secret do env file + trigger (idempotente)
#   ./scripts/cloudbuild.sh prod run      # sincroniza envs/prod.env → secret, dispara o trigger e segue o log
#   ./scripts/cloudbuild.sh dev submit    # idem, mas com a SUA árvore local (gcloud builds submit) — para
#                                         # testar mudanças no cloudbuild.yaml/scripts antes do push
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
# Bucket onde `gcloud builds submit` sobe a árvore local (só a ação `submit`
# usa; o trigger lê o código direto do GitHub).
SOURCE_BUCKET="gs://${PROJECT}_cloudbuild"
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

# Os logs ficam só no Cloud Logging (options.logging: CLOUD_LOGGING_ONLY);
# `gcloud builds log --stream` só lê de bucket, então lemos do Logging direto.
log_do_build() {
  gcloud logging read "resource.type=build AND resource.labels.build_id=$1" \
    --project="$PROJECT" --order=asc --limit=5000 --format='value(textPayload)'
}

# Segue o build até terminar, imprimindo as linhas novas do log a cada 5 s.
acompanhar() {
  local id="$1" visto=0 linhas total status
  echo "  build ${id}"
  echo "  https://console.cloud.google.com/cloud-build/builds;region=${REGION}/${id}?project=${PROJECT}"
  echo
  while :; do
    status="$(gcloud builds describe "$id" "${CB[@]}" --format='value(status)')"
    linhas="$(log_do_build "$id")"
    if [ -n "$linhas" ]; then
      total="$(printf '%s\n' "$linhas" | wc -l | tr -d ' ')"
      if [ "$total" -gt "$visto" ]; then
        printf '%s\n' "$linhas" | tail -n +"$((visto + 1))"; visto="$total"
      fi
    fi
    case "$status" in
      SUCCESS) echo; log "build ${id}: SUCCESS"; return 0 ;;
      FAILURE|TIMEOUT|CANCELLED|INTERNAL_ERROR|EXPIRED) echo; die "build ${id} terminou com status ${status}" ;;
    esac
    sleep 5
  done
}

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

    log "Leitura do bucket de source (${SOURCE_BUCKET}) para a ação submit"
    gcloud storage buckets add-iam-policy-binding "$SOURCE_BUCKET" --project="$PROJECT" \
      --member="serviceAccount:${SA}" --role=roles/storage.objectViewer --quiet >/dev/null \
      && echo "  ok      roles/storage.objectViewer em ${SOURCE_BUCKET}" \
      || warn "não consegui dar leitura em ${SOURCE_BUCKET} (o bucket só existe após o 1º gcloud builds submit)"

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
    gcloud builds triggers create manual --name="$TRIGGER" "${CB[@]}" \
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
    acompanhar "$BUILD_ID"
    ;;

  submit)
    # Sobe a árvore local (respeita .gitignore: envs/*.env ficam de fora) e
    # roda o mesmo cloudbuild.yaml. Não passa pelo trigger nem pelo GitHub.
    "${ROOT_DIR}/scripts/secrets.sh" "$ENV_NAME" env-file
    log "gcloud builds submit (árvore local, _ENV=${ENV_NAME})"
    BUILD_ID="$(cd "$ROOT_DIR" && gcloud builds submit . "${CB[@]}" --config=cloudbuild.yaml \
      --substitutions="_ENV=${ENV_NAME}" --async --format='value(id)')" \
      || die "gcloud builds submit falhou (veja acima; a SA precisa ler ${SOURCE_BUCKET} — rode: $0 ${ENV_NAME} setup)"
    BUILD_ID="$(printf '%s\n' "$BUILD_ID" | tail -1)"
    [ -n "$BUILD_ID" ] || die "não consegui submeter o build"
    acompanhar "$BUILD_ID"
    ;;

  builds)
    gcloud builds list "${CB[@]}" --filter="substitutions._ENV=${ENV_NAME}" --limit=10 \
      --format='table(id,status,createTime.date(tz=LOCAL),duration(),substitutions._ENV)'
    ;;

  log)
    BUILD_ID="${3:-}"
    [ -n "$BUILD_ID" ] || BUILD_ID="$(gcloud builds list "${CB[@]}" --filter="substitutions._ENV=${ENV_NAME}" --limit=1 --format='value(id)')"
    [ -n "$BUILD_ID" ] || die "nenhum build de ${ENV_NAME} ainda"
    log_do_build "$BUILD_ID"
    ;;

  *) die "ação desconhecida: ${ACAO} (setup|run|submit|builds|log)" ;;
esac
