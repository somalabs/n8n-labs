#!/usr/bin/env bash
# Prepara o lado GCP de uma VM que JÁ existe (não cria VM):
#   - habilita as APIs (Secret Manager, Compute, Cloud SQL Admin)
#   - aumenta o disco de boot (10 GB de fábrica é pouco para imagens + backups)
#   - agenda snapshot diário do disco (backup "de desastre" do n8n_data e dos
#     dumps; o banco em si vive no Cloud SQL, com backup próprio)
#   - confere se o DNS de N8N_HOST aponta para o IP interno da VM
# Idempotente: pode rodar de novo à vontade. Não reinicia a VM.
#
# Não mexe em IP externo nem em tags de firewall: o acesso é pelo DNS interno
# (registro A → IP interno) e a regra allow-internal-in da soma-network já
# libera a rede da empresa para qualquer porta da VM.
#
#   ./scripts/gcp-setup.sh prod

set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud

log "Habilitando APIs (secretmanager, compute, sqladmin)"
gcloud services enable secretmanager.googleapis.com compute.googleapis.com sqladmin.googleapis.com \
  --project="$PROJECT" --quiet

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

log "DNS de ${N8N_HOST}"
INTERNO="$(vm_internal_ip)"
RESOLVIDO="$(dig +short "$N8N_HOST" 2>/dev/null | head -1 || true)"
if [ "$RESOLVIDO" = "$INTERNO" ]; then
  echo "  ${N8N_HOST} → ${INTERNO} (IP interno de ${VM}) ok"
elif [ -z "$RESOLVIDO" ]; then
  warn "${N8N_HOST} não resolve daqui. Fora da VPN é esperado; na VPN, confira o registro A → ${INTERNO}"
else
  warn "${N8N_HOST} resolve para ${RESOLVIDO}, mas o IP interno de ${VM} é ${INTERNO}"
fi

echo
echo "Próximos passos: make secrets ENV=${ENV_NAME} && make bootstrap ENV=${ENV_NAME} && make deploy ENV=${ENV_NAME}"
