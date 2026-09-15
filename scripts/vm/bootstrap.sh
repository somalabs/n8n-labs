#!/usr/bin/env bash
# Roda NA VM (Debian 13), uma vez, como root — via `make bootstrap ENV=...`,
# que faz: gcloud compute ssh ... -- 'sudo bash -s' < scripts/vm/bootstrap.sh
#
#   - expande o filesystem raiz se o disco foi aumentado no GCP
#   - instala Docker CE + compose plugin (repo oficial da Docker)
#   - limita logs dos containers (senão json-file cresce até encher o disco)
#   - cria /opt/n8n e agenda o backup diário
#   - atualizações de segurança automáticas
# Idempotente.

set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "rode como root (sudo)"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

echo "==> Filesystem raiz"
apt-get install -y -qq cloud-guest-utils >/dev/null 2>&1 || true
ROOT_DEV="$(findmnt -n -o SOURCE /)"            # ex.: /dev/sda1
DISK="/dev/$(lsblk -no PKNAME "$ROOT_DEV")"     # ex.: /dev/sda
PART="$(echo "$ROOT_DEV" | grep -o '[0-9]*$')"
growpart "$DISK" "$PART" 2>/dev/null && resize2fs "$ROOT_DEV" >/dev/null 2>&1 || true
df -h / | tail -1

echo "==> Pacotes base"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg rsync unattended-upgrades cron >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Docker CE"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
else
  echo "==> Docker já instalado: $(docker --version)"
fi

echo "==> Limite de logs do Docker"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
JSON
systemctl enable docker >/dev/null 2>&1
systemctl restart docker

# Deixa o usuário que fez o ssh usar docker sem sudo (vale a partir do próximo login).
if [ -n "${SUDO_USER:-}" ]; then usermod -aG docker "$SUDO_USER"; fi

echo "==> /opt/n8n e backup diário (03:30)"
mkdir -p /opt/n8n/backups /opt/n8n/local-files /opt/n8n/scripts
chmod 700 /opt/n8n/backups
cat > /etc/cron.d/n8n-backup <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 3 * * * root [ -x /opt/n8n/scripts/backup.sh ] && /opt/n8n/scripts/backup.sh >> /var/log/n8n-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/n8n-backup
systemctl enable cron >/dev/null 2>&1 || true

echo "==> Atualizações de segurança automáticas"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
# Sem reboot automático: a VM só reinicia quando alguém decidir.

echo
echo "==> Bootstrap concluído: $(docker --version) | $(docker compose version)"
echo "    Agora rode, da sua máquina: make deploy ENV=<prod|dev>"
