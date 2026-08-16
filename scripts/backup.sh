#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

kind="${1:-scheduled}"
backup_id="${2:-$(date -u +%Y%m%dT%H%M%SZ)}"
case "$kind" in scheduled|predeploy|manual) ;; *) echo "Unsupported backup kind" >&2; exit 2 ;; esac
[[ "$backup_id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid backup identifier" >&2; exit 2; }

data_root=/var/lib/assembly-os/data
backup_root=/var/backups/assembly-os
retention=14
if [[ -r /etc/assembly-os/backup.env ]]; then
  # This root-owned file is generated from a validated numeric GitHub variable.
  source /etc/assembly-os/backup.env
  retention="${BACKUP_RETENTION_DAYS:-14}"
fi
[[ "$retention" =~ ^[0-9]+$ ]] && (( retention >= 1 && retention <= 365 )) || exit 2

destination="$backup_root/$kind/$backup_id"
work="$(mktemp -d "$backup_root/.backup.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
install -d -m 0700 "$destination"

if [[ -f "$data_root/assambleya.db" ]]; then
  sqlite3 "$data_root/assambleya.db" ".timeout 10000" ".backup '$work/assambleya.db'"
  sqlite3 "$work/assambleya.db" 'PRAGMA quick_check;' | grep -Fxq ok
  install -m 0600 "$work/assambleya.db" "$destination/assambleya.db"
fi

if [[ -d "$data_root/uploads" ]]; then
  tar --numeric-owner -C "$data_root" -czf "$destination/uploads.tar.gz" uploads
fi

(
  cd "$destination"
  sha256sum -- * > SHA256SUMS
)
date -u +%FT%TZ > "$destination/created-at"
find "$backup_root" -mindepth 2 -maxdepth 2 -type d -mtime "+$retention" -exec rm -rf -- {} +
printf '%s\n' "$destination"
