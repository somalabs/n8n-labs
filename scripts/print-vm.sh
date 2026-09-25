#!/usr/bin/env bash
# Imprime nome ou zona da VM de um ambiente (usado pelo Makefile).
#   ./scripts/print-vm.sh prod name   → n8n-prod
#   ./scripts/print-vm.sh prod zone   → us-central1-a
#   ./scripts/print-vm.sh prod internal-ip → 10.0.96.72 (alvo do registro A)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
case "${2:-name}" in name) echo "$VM" ;; zone) echo "$ZONE" ;; ip) vm_ip ;; internal-ip) vm_internal_ip ;; *) exit 1 ;; esac
