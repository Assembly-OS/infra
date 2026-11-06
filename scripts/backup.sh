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
  # shellcheck disable=SC1091
  source /etc/assembly-os/backup.env
  retention="${BACKUP_RETENTION_DAYS:-14}"
fi
[[ "$retention" =~ ^[0-9]+$ ]] && (( retention >= 1 && retention <= 365 )) || exit 2

destination="$backup_root/$kind/$backup_id"
work="$(mktemp -d "$backup_root/.backup.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
[[ ! -e "$destination" ]] || { echo "Backup ID already exists" >&2; exit 2; }
install -d -m 0700 "$destination"

# Fail closed: a media-only backup must never look like a complete backup.
/usr/local/sbin/assembly-os-project-db dump --file "$work/database.dump"
install -m 0600 "$work/database.dump" "$destination/database.dump"
python3 - "$destination" <<'PYTHON'
import json, pathlib, sys
config = json.loads(pathlib.Path('/etc/assembly-os/database.json').read_text())
pathlib.Path(sys.argv[1], 'identity.json').write_text(json.dumps({
    'project': 'assembly-os', 'database': config['DB_NAME'], 'role': config['DB_USER']}))
# Preserve the bot's legacy SQLite store using SQLite's online backup API.
source = pathlib.Path('/var/lib/assembly-os/data/assambleya.db')
if source.exists():
    import sqlite3
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as original:
        with sqlite3.connect(str(pathlib.Path(sys.argv[1], 'assambleya.db'))) as copy:
            original.backup(copy)
            if copy.execute('PRAGMA quick_check').fetchone() != ('ok',):
                raise SystemExit('Legacy database integrity check failed')
PYTHON
[[ -d "$data_root/uploads" ]] || { echo "Project uploads directory is missing" >&2; exit 2; }
tar --numeric-owner -C "$data_root" -czf "$destination/uploads.tar.gz" uploads

(
  cd "$destination"
  sha256sum -- * > SHA256SUMS
)
date -u +%FT%TZ > "$destination/created-at"
# Keep manual/cutover and predeploy snapshots until an operator explicitly archives them.
find "$backup_root/scheduled" -mindepth 1 -maxdepth 1 -type d -mtime "+$retention" -exec rm -rf -- {} +
printf '%s\n' "$destination"
