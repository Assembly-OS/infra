#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

deploy_root="${1:-/opt/assembly-os}"
ssh_port="${2:-22}"
perform_upgrade="${3:-true}"
source_root="${4:-}"
backup_retention="${5:-14}"

[[ "$(id -u)" -eq 0 ]] || { echo "Bootstrap must run as root" >&2; exit 2; }
[[ "$deploy_root" == /opt/* && "$deploy_root" != /opt ]] || { echo "DEPLOY_ROOT must be below /opt" >&2; exit 2; }
[[ "$ssh_port" =~ ^[0-9]+$ ]] && (( ssh_port >= 1 && ssh_port <= 65535 )) || { echo "Invalid SSH port" >&2; exit 2; }
[[ "$perform_upgrade" == true || "$perform_upgrade" == false ]] || { echo "Invalid upgrade flag" >&2; exit 2; }
[[ "$backup_retention" =~ ^[0-9]+$ ]] && (( backup_retention >= 1 && backup_retention <= 365 )) || { echo "Invalid backup retention" >&2; exit 2; }
[[ -d "$source_root" && -f "$source_root/models/checksums.tsv" ]] || { echo "Bootstrap source bundle is incomplete" >&2; exit 2; }

source /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 26.04 ]] || {
  echo "Ubuntu 26.04 is required; found ${PRETTY_NAME:-unknown}" >&2
  exit 2
}
[[ "$(dpkg --print-architecture)" == amd64 ]] || { echo "amd64 is required" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
if [[ "$perform_upgrade" == true ]]; then
  apt-get -y full-upgrade
fi
apt-get install -y --no-install-recommends \
  ca-certificates curl fail2ban gnupg jq rsync sqlite3 tar ufw unattended-upgrades xz-utils

install -d -m 0755 /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
  curl --proto '=https' --tlsv1.2 -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
fi
chmod 0644 /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y --no-install-recommends \
  containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-compose-plugin

install -d -m 0755 /etc/docker
daemon_tmp="$(mktemp)"
if [[ -s /etc/docker/daemon.json ]]; then
  jq '. + {"live-restore": true, "no-new-privileges": true, "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' \
    /etc/docker/daemon.json > "$daemon_tmp"
else
  jq -n '{"live-restore": true, "no-new-privileges": true, "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > "$daemon_tmp"
fi
install -o root -g root -m 0644 "$daemon_tmp" /etc/docker/daemon.json
rm -f "$daemon_tmp"
systemctl enable --now docker
systemctl restart docker
docker info >/dev/null
docker buildx version
docker compose version

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/60-assembly-os.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
X11Forwarding no
AllowAgentForwarding no
EOF
sshd -t
systemctl reload ssh

cat > /etc/fail2ban/jail.d/assembly-os-sshd.local <<EOF
[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
maxretry = 5
bantime = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

ufw default deny incoming
ufw default allow outgoing
ufw allow "${ssh_port}/tcp" comment 'SSH'
ufw allow 80/tcp comment 'HTTP for ACME redirect'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'HTTP/3'
ufw --force enable

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades

install -d -o root -g root -m 0755 "$deploy_root" "$deploy_root/current" "$deploy_root/releases" "$deploy_root/.staging"
install -d -o root -g root -m 0700 /etc/assembly-os /var/backups/assembly-os
install -d -o root -g root -m 0700 /var/backups/assembly-os/scheduled /var/backups/assembly-os/predeploy /var/backups/assembly-os/manual
install -d -m 0750 /var/lib/assembly-os/data /var/lib/assembly-os/data/uploads
install -d -o root -g root -m 0755 /var/lib/assembly-os/models
install -d -m 0750 /var/lib/assembly-os/caddy/data /var/lib/assembly-os/caddy/config
chown 10001:10001 \
  /var/lib/assembly-os/data /var/lib/assembly-os/data/uploads \
  /var/lib/assembly-os/caddy/data /var/lib/assembly-os/caddy/config
printf '%s\n' "$deploy_root" > /etc/assembly-os/deploy-root
chmod 0600 /etc/assembly-os/deploy-root
printf "BACKUP_RETENTION_DAYS='%s'\n" "$backup_retention" > /etc/assembly-os/backup.env
chmod 0600 /etc/assembly-os/backup.env

while read -r checksum filename url; do
  [[ -z "$checksum" || "$checksum" == \#* ]] && continue
  [[ "$checksum" =~ ^[0-9a-f]{64}$ && "$filename" =~ ^[A-Za-z0-9._-]+$ && "$url" == https://* ]] || {
    echo "Invalid model manifest entry" >&2
    exit 2
  }
  target="/var/lib/assembly-os/models/$filename"
  if [[ -f "$target" ]] && echo "$checksum  $target" | sha256sum -c - >/dev/null 2>&1; then
    continue
  fi
  temporary="${target}.part"
  rm -f -- "$temporary"
  curl --proto '=https' --tlsv1.2 --location --fail --retry 5 --retry-all-errors \
    --output "$temporary" "$url"
  echo "$checksum  $temporary" | sha256sum -c -
  install -o root -g root -m 0444 "$temporary" "$target"
  rm -f -- "$temporary"
done < "$source_root/models/checksums.tsv"

install -o root -g root -m 0755 "$source_root/scripts/backup.sh" /usr/local/sbin/assembly-os-backup
install -o root -g root -m 0755 "$source_root/scripts/restore.sh" /usr/local/sbin/assembly-os-restore
install -o root -g root -m 0644 "$source_root/systemd/assembly-os-backup.service" /etc/systemd/system/assembly-os-backup.service
install -o root -g root -m 0644 "$source_root/systemd/assembly-os-backup.timer" /etc/systemd/system/assembly-os-backup.timer
systemctl daemon-reload
systemctl enable --now assembly-os-backup.timer

echo "Bootstrap complete. Reboot required: $([[ -f /var/run/reboot-required ]] && echo yes || echo no)"
