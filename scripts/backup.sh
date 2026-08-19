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

deploy_root="$(</etc/assembly-os/deploy-root)"
[[ "$deploy_root" == /opt/* ]] || { echo "Invalid deploy root" >&2; exit 2; }
compose=(docker compose -p assembly-os
  --env-file "$deploy_root/current/apps/backend/image.env"
  --env-file "$deploy_root/current/apps/frontend/image.env"
  --env-file "$deploy_root/current/apps/bot/image.env"
  -f "$deploy_root/current/compose.yaml")

destination="$backup_root/$kind/$backup_id"
work="$(mktemp -d "$backup_root/.backup.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
install -d -m 0700 "$destination"

# The dump runs inside the container so pg_dump always matches the server it
# reads and the host needs no Postgres client package. An absent stack is the
# state a missing SQLite file used to stand for: a bootstrapped server whose
# first deployment has not landed yet, which has nothing to save.
if [[ -f "$deploy_root/current/compose.yaml" && -n "$("${compose[@]}" ps -q postgres)" ]]; then
  "${compose[@]}" exec -T postgres sh -c \
    'pg_dump --clean --if-exists --no-owner --no-privileges --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"' \
    | gzip -c > "$work/assambleya.sql.gz"
  gzip -t "$work/assambleya.sql.gz"
  # pg_dump writes this trailer last. A dump interrupted halfway still gzips
  # cleanly, so the trailer is what separates a whole backup from a torso.
  gzip -cd "$work/assambleya.sql.gz" | tail -n 5 | grep -Fq 'PostgreSQL database dump complete'
  install -m 0600 "$work/assambleya.sql.gz" "$destination/assambleya.sql.gz"
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
