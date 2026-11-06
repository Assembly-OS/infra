#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

deploy_root="${1:-/opt/assembly-os}"
ssh_port="${2:-22}"
perform_upgrade="${3:-false}"
source_root="${4:-}"
backup_retention="${5:-14}"

[[ "$(id -u)" -eq 0 ]] || { echo "Bootstrap must run as root" >&2; exit 2; }
[[ "$deploy_root" == /opt/assembly-os ]] || { echo "DEPLOY_ROOT must be below /opt" >&2; exit 2; }
if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then echo "Invalid SSH port" >&2; exit 2; fi
[[ "$perform_upgrade" == true || "$perform_upgrade" == false ]] || { echo "Invalid upgrade flag" >&2; exit 2; }
if ! [[ "$backup_retention" =~ ^[0-9]+$ ]] || (( backup_retention < 1 || backup_retention > 365 )); then echo "Invalid backup retention" >&2; exit 2; fi
[[ -d "$source_root" && -f "$source_root/models/checksums.tsv" ]] || { echo "Bootstrap source bundle is incomplete" >&2; exit 2; }

# This host is already provisioned. Missing prerequisites are an operator task.
for command in docker python3 rsync curl tar flock; do
  command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 2; }
done
docker info >/dev/null
docker compose version >/dev/null
python3 "$source_root/scripts/project-db.py" check --config "$source_root/config/database.json"
[[ "$perform_upgrade" == false ]] || { echo "Host upgrades are prohibited by this bootstrap" >&2; exit 2; }
deploy_user="${6:-deploy}"
[[ "$deploy_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 2
id "$deploy_user" >/dev/null
deploy_group="$(id -gn "$deploy_user")"
install -d -o root -g root -m 0755 "$deploy_root" "$deploy_root/current" "$deploy_root/releases"
install -d -o "$deploy_user" -g "$deploy_group" -m 0700 "$deploy_root/.staging"
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
# Install project configuration only; no shared infrastructure credentials are needed.
for file in backend.env frontend.env bot.env caddy.env backup.env compose.env database.json; do
  if [[ "$file" == bot.env && -f /etc/assembly-os/bot.env ]]; then continue; fi
  install -o root -g root -m 0600 "$source_root/config/$file" "/etc/assembly-os/$file"
done


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

install -o root -g root -m 0755 "$source_root/scripts/project-db.py" /usr/local/sbin/assembly-os-project-db
install -o root -g root -m 0755 "$source_root/scripts/backup.sh" /usr/local/sbin/assembly-os-backup
install -o root -g root -m 0755 "$source_root/scripts/restore-media.py" /usr/local/sbin/assembly-os-restore-media
install -o root -g root -m 0755 "$source_root/scripts/restore.sh" /usr/local/sbin/assembly-os-restore
install -o root -g root -m 0644 "$source_root/systemd/assembly-os-backup.service" /etc/systemd/system/assembly-os-backup.service
install -o root -g root -m 0644 "$source_root/systemd/assembly-os-backup.timer" /etc/systemd/system/assembly-os-backup.timer
systemctl daemon-reload
# Enabled only after the approved restore and verification.
if [[ -f /var/lib/assembly-os/restore-verified ]]; then
  python3 "$source_root/scripts/project-db.py" check --require-restored
  systemctl enable --now assembly-os-backup.timer
fi

echo "Project storage and maintenance prepared; host services were not changed."
