#!/usr/bin/env bash
# Funções e constantes compartilhadas pelos scripts locais (rodam na SUA
# máquina, com gcloud autenticado). Uso: source "$(dirname "$0")/lib.sh"; carregar_env "$1"

PROJECT="soma-ai-hub"
REGION="us-central1"
REMOTE_DIR="/opt/n8n"
# Instância Cloud SQL (Postgres) compartilhada por dev e prod; cada ambiente
# tem database/usuário próprios (POSTGRES_DB/POSTGRES_USER em envs/<env>.env).
CLOUDSQL_INSTANCE="n8n"

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

# Como chegar na VM por SSH.
#
# As VMs vivem na Shared VPC `soma-network` (host project soma-infra-network),
# cujo firewall só aceita a porta 22 vindo de dentro da rede da empresa (VPN /
# ranges internos) ou do range do IAP (35.235.240.0/20, regra
# `allow-ingress-from-iap`). De fora da VPN — Cloud Build, sua máquina em
# casa — o IP público da VM não responde na 22 nem na 443.
#
# Mesmo NA VPN o `gcloud compute ssh` padrão mira o IP público e dá timeout:
# a conexão sai pela internet e chega ao firewall vinda de fora dos ranges
# internos. Por isso o padrão aqui é o túnel pelo Identity-Aware Proxy
# (`--tunnel-through-iap`), que funciona de qualquer lugar. Quem roda precisa
# do papel roles/iap.tunnelResourceAccessor no projeto.
#
#   SSH_VIA_IAP=0 make ssh ENV=dev        # força ssh direto (só se souber o que está fazendo)
SSH_VIA_IAP="${SSH_VIA_IAP:-1}"

# Usuário Linux na VM. Vazio = o usuário local (padrão do gcloud). O worker do
# Cloud Build roda como root, e as imagens do GCE recusam login de root por ssh
# (PermitRootLogin no) — por isso o cloudbuild.yaml define SSH_USER=cloudbuild.
# A chave vai para os metadados do projeto como "<SSH_USER>:ssh-rsa ..." e o
# guest agent cria o usuário na VM com sudo sem senha.
SSH_USER="${SSH_USER:-}"
SSH_TARGET="${SSH_USER:+${SSH_USER}@}"

# Chaves efêmeras: `gcloud compute ssh` registra a chave da máquina de quem
# roda nos metadados do projeto. Com expiração, as chaves de workers
# descartáveis do Cloud Build não se acumulam como acesso permanente.
SSH_KEY_TTL="${SSH_KEY_TTL:-1h}"

# Flags comuns a `gcloud compute ssh` e `gcloud compute scp`.
gcloud_ssh_flags() {
  local flags=(--project="$PROJECT" --quiet --ssh-key-expire-after="$SSH_KEY_TTL")
  [ "$SSH_VIA_IAP" = 1 ] && flags+=(--tunnel-through-iap)
  printf '%s\n' "${flags[@]}"
}

vm_ssh() {
  local flags=(); while IFS= read -r f; do flags+=("$f"); done < <(gcloud_ssh_flags)
  gcloud compute ssh "${SSH_TARGET}${VM}" --zone="$ZONE" "${flags[@]}" -- "$@"
}
vm_scp() {
  local flags=(); while IFS= read -r f; do flags+=("$f"); done < <(gcloud_ssh_flags)
  # Os chamadores escrevem "${VM}:caminho"; prefixamos o usuário aqui.
  local args=() a; for a in "$@"; do args+=("${a/#${VM}:/${SSH_TARGET}${VM}:}"); done
  gcloud compute scp --zone="$ZONE" "${flags[@]}" "${args[@]}"
}
# Shell interativo (sem `--`; deixa o gcloud alocar o TTY).
vm_shell() {
  local flags=(); while IFS= read -r f; do flags+=("$f"); done < <(gcloud_ssh_flags)
  gcloud compute ssh "${SSH_TARGET}${VM}" --zone="$ZONE" "${flags[@]}"
}
vm_ip() {
  gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
}
vm_internal_ip() {
  gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT" \
    --format="value(networkInterfaces[0].networkIP)"
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33maviso:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merro:\033[0m %s\n' "$*" >&2; exit 1; }

exigir() { command -v "$1" >/dev/null 2>&1 || die "preciso de '$1' no PATH"; }
