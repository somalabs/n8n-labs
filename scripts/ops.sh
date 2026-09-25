#!/usr/bin/env bash
# Operação do dia a dia, da sua máquina:
#   ./scripts/ops.sh prod status          # docker compose ps + disco + memória
#   ./scripts/ops.sh prod logs [serviço]  # segue logs (n8n, n8n-worker, redis)
#   ./scripts/ops.sh prod ssh             # shell na VM
#   ./scripts/ops.sh prod psql            # psql no Cloud SQL, a partir da VM
#   ./scripts/ops.sh prod restart [serviço]
#   ./scripts/ops.sh prod backup          # roda o backup agora
#   ./scripts/ops.sh prod backups         # lista backups na VM
#   ./scripts/ops.sh prod fetch-backup <arquivo>   # baixa um backup para ./backups/
#   ./scripts/ops.sh prod restore <arquivo>        # restaura um dump no Cloud SQL (pede confirmação)
#   ./scripts/ops.sh prod migrate-db      # postgres antigo da VM → Cloud SQL (uma vez)
#   ./scripts/ops.sh prod down            # para tudo (dados ficam nos volumes / Cloud SQL)

set -euo pipefail
source "$(dirname "$0")/lib.sh"
carregar_env "${1:-}"
exigir gcloud
ACAO="${2:-status}"; ARG="${3:-}"
DC="cd ${REMOTE_DIR} && sudo docker compose"

case "$ACAO" in
  status)  vm_ssh "$DC ps; echo; df -h / | tail -1; echo; free -h | head -2" ;;
  logs)    vm_ssh -t "$DC logs -f --tail=200 ${ARG}" ;;
  ssh)     vm_shell ;;
  psql)    vm_ssh -t "sudo ${REMOTE_DIR}/scripts/psql.sh" ;;
  restart) vm_ssh "$DC restart ${ARG}" ;;
  down)    vm_ssh "$DC down" ;;
  backup)  vm_ssh "sudo ${REMOTE_DIR}/scripts/backup.sh" ;;
  backups) vm_ssh "ls -lh ${REMOTE_DIR}/backups/" ;;
  restore)
    [ -n "$ARG" ] || die "uso: $0 ${ENV_NAME} restore <arquivo em ${REMOTE_DIR}/backups/>"
    vm_ssh -t "sudo ${REMOTE_DIR}/scripts/restore.sh ${REMOTE_DIR}/backups/${ARG}" ;;
  migrate-db) vm_ssh -t "sudo ${REMOTE_DIR}/scripts/migrate-to-cloudsql.sh" ;;
  fetch-backup)
    [ -n "$ARG" ] || die "uso: $0 ${ENV_NAME} fetch-backup <arquivo>"
    mkdir -p "${ROOT_DIR}/backups"
    vm_ssh "sudo cp ${REMOTE_DIR}/backups/${ARG} ~/ && sudo chown \$USER ~/${ARG}"
    vm_scp "${VM}:~/${ARG}" "${ROOT_DIR}/backups/"
    vm_ssh "rm -f ~/${ARG}"
    echo "  salvo em backups/${ARG}" ;;
  *) die "ação desconhecida: ${ACAO}" ;;
esac
