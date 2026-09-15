#!/usr/bin/env bash
# Funções e constantes compartilhadas pelos scripts locais (rodam na SUA
# máquina, com gcloud autenticado). Uso: source "$(dirname "$0")/lib.sh"; carregar_env "$1"

PROJECT="soma-ai-hub"
REGION="us-central1"
REMOTE_DIR="/opt/n8n"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Mapeia ambiente → VM. As duas VMs já existem; só apontamos para elas.
carregar_env() {
  ENV_NAME="${1:-}"
  case "$ENV_NAME" in
    prod) VM="n8n-prod"; ZONE="us-central1-a"; DISK_SIZE_GB=50; SNAPSHOT_RETENTION_DAYS=14 ;;
    dev)  VM="n8n-dev";  ZONE="us-central1-f"; DISK_SIZE_GB=20; SNAPSHOT_RETENTION_DAYS=7 ;;
    *) echo "uso: $0 <prod|dev>" >&2; exit 1 ;;
  esac
  ENV_FILE="${ROOT_DIR}/envs/${ENV_NAME}.env"
  [ -f "$ENV_FILE" ] || { echo "não achei ${ENV_FILE}"; exit 1; }
  # Exporta as variáveis não sensíveis para uso nos scripts (N8N_HOST etc.).
  set -a; # shellcheck disable=SC1090
  source "$ENV_FILE"; set +a
}

# Nomes dos secrets no Secret Manager. Um conjunto por ambiente.
secret_id() { echo "n8n-${ENV_NAME}-$1"; }
SECRET_VARS=(
  "POSTGRES_PASSWORD:postgres-password"
  "N8N_ENCRYPTION_KEY:encryption-key"
  "N8N_JWT_SECRET:jwt-secret"
)

vm_ssh() {
  gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" --quiet -- "$@"
}
vm_scp() {
  gcloud compute scp --zone="$ZONE" --project="$PROJECT" --quiet "$@"
}
vm_ip() {
  gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33maviso:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merro:\033[0m %s\n' "$*" >&2; exit 1; }

exigir() { command -v "$1" >/dev/null 2>&1 || die "preciso de '$1' no PATH"; }
