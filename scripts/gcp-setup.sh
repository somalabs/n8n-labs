#!/usr/bin/env bash
# Prepara o lado GCP de uma VM que JÁ existe (não cria VM):
#   - tags http-server/https-server (as regras de firewall da soma-network
#     liberam 80/443 só para quem tem essas tags)
#   - promove o IP efêmero a estático (o sslip.io/DNS depende dele não mudar)
#   - aumenta o disco de boot (10 GB de fábrica é pouco para postgres + imagens)
#   - agenda snapshot diário do disco (é o backup "de desastre"; o pg_dump
#     local é o backup "de rotina")
#   - habilita a API do Secret Manager
# Idempotente: pode rodar de novo à vontade. Não reinicia a VM.
#
#   ./scripts/gcp-setup.sh prod

set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud

log "Habilitando APIs (secretmanager, compute)"
gcloud services enable secretmanager.googleapis.com compute.googleapis.com --project="$PROJECT" --quiet

log "Tags de firewall em ${VM}"
gcloud compute instances add-tags "$VM" --zone="$ZONE" --project="$PROJECT" \
  --tags=http-server,https-server --quiet

log "IP estático"
IP="$(vm_ip)"
ADDR_NAME="${VM}-ip"
if gcloud compute addresses describe "$ADDR_NAME" --region="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
  echo "  ${ADDR_NAME} já existe ($(gcloud compute addresses describe "$ADDR_NAME" --region="$REGION" --project="$PROJECT" --format='value(address)'))"
else
  # Promover o IP atual mantém o que já está em uso (nada muda para quem já aponta pra ele).
  gcloud compute addresses create "$ADDR_NAME" --region="$REGION" --project="$PROJECT" \
    --addresses="$IP" --quiet
  echo "  ${IP} promovido a estático como ${ADDR_NAME}"
fi

log "Disco de boot → ${DISK_SIZE_GB} GB"
DISK="$(gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT" --format='value(disks[0].source.basename())')"
ATUAL="$(gcloud compute disks describe "$DISK" --zone="$ZONE" --project="$PROJECT" --format='value(sizeGb)')"
if [ "$ATUAL" -ge "$DISK_SIZE_GB" ]; then
  echo "  ${DISK} já tem ${ATUAL} GB"
else
  gcloud compute disks resize "$DISK" --zone="$ZONE" --project="$PROJECT" --size="${DISK_SIZE_GB}GB" --quiet
  echo "  ${DISK}: ${ATUAL} → ${DISK_SIZE_GB} GB (o bootstrap.sh expande o filesystem na VM)"
fi

log "Snapshot diário do disco (retém ${SNAPSHOT_RETENTION_DAYS} dias)"
POLICY="${VM}-daily-snapshot"
if ! gcloud compute resource-policies describe "$POLICY" --region="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
  gcloud compute resource-policies create snapshot-schedule "$POLICY" \
    --region="$REGION" --project="$PROJECT" \
    --max-retention-days="$SNAPSHOT_RETENTION_DAYS" \
    --daily-schedule --start-time=06:00 \
    --on-source-disk-delete=keep-auto-snapshots \
    --storage-location="$REGION" --quiet
fi
if gcloud compute disks describe "$DISK" --zone="$ZONE" --project="$PROJECT" --format='value(resourcePolicies)' | grep -q "$POLICY"; then
  echo "  ${POLICY} já anexada a ${DISK}"
else
  gcloud compute disks add-resource-policies "$DISK" --zone="$ZONE" --project="$PROJECT" \
    --resource-policies="$POLICY" --quiet
  echo "  ${POLICY} anexada a ${DISK}"
fi

echo
log "Pronto. Host sugerido sem DNS: ${IP}.sslip.io"
[ "${N8N_HOST}" = "${IP}.sslip.io" ] || warn "envs/${ENV_NAME}.env tem N8N_HOST=${N8N_HOST}; confira se aponta para ${IP}"
echo "Próximos passos: make secrets ENV=${ENV_NAME} && make bootstrap ENV=${ENV_NAME} && make deploy ENV=${ENV_NAME}"
