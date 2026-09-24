#!/usr/bin/env bash
# Prepara a VM (docker, cron de backup, logs, updates). Roda scripts/vm/bootstrap.sh
# lá dentro via ssh. Uma vez por VM; idempotente.
#   ./scripts/bootstrap.sh prod
set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud
log "Bootstrap de ${VM} (${ZONE})"
vm_ssh 'sudo bash -s' < "${ROOT_DIR}/scripts/vm/bootstrap.sh"
