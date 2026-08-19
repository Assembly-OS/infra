#!/usr/bin/env bash
set -Eeuo pipefail

backup_dir="${1:-}"
confirmation="${2:-}"
[[ "$confirmation" == --confirm-restore ]] || {
  echo "Usage: assembly-os-restore /var/backups/assembly-os/<kind>/<id> --confirm-restore" >&2
  exit 2
}
backup_dir="$(readlink -f -- "$backup_dir")"
[[ "$backup_dir" == /var/backups/assembly-os/* && -f "$backup_dir/SHA256SUMS" ]] || {
  echo "Backup path is outside the Assembly OS backup root or is incomplete" >&2
  exit 2
}
(cd "$backup_dir" && sha256sum -c SHA256SUMS)

deploy_root="$(</etc/assembly-os/deploy-root)"
[[ "$deploy_root" == /opt/* ]] || { echo "Invalid deploy root" >&2; exit 2; }
compose=(docker compose -p assembly-os
  --env-file "$deploy_root/current/apps/backend/image.env"
  --env-file "$deploy_root/current/apps/frontend/image.env"
  --env-file "$deploy_root/current/apps/bot/image.env"
  -f "$deploy_root/current/compose.yaml")

/usr/local/sbin/assembly-os-backup manual "before-restore-$(date -u +%Y%m%dT%H%M%SZ)"
"${compose[@]}" stop backend frontend bot
# Only the readers stop; the database itself has to be up to be restored into.
"${compose[@]}" up -d postgres
if [[ -f "$backup_dir/assambleya.sql.gz" ]]; then
  gzip -t "$backup_dir/assambleya.sql.gz"
  # The dump drops what it is about to recreate, and one transaction means the
  # database is either the backup or what it was before, never a mixture.
  gzip -cd "$backup_dir/assambleya.sql.gz" | "${compose[@]}" exec -T postgres sh -c \
    'psql --quiet --single-transaction --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"' \
    >/dev/null
fi
if [[ -f "$backup_dir/uploads.tar.gz" ]]; then
  tar -tzf "$backup_dir/uploads.tar.gz" >/dev/null
  found_uploads=false
  while IFS= read -r member; do
    [[ "$member" == uploads || "$member" == uploads/* ]] || {
      echo "Upload archive contains a path outside uploads" >&2
      exit 2
    }
    [[ "$member" != /* && "$member" != ../* && "$member" != *"/../"* && "$member" != *"/.." ]] || {
      echo "Upload archive contains an unsafe path" >&2
      exit 2
    }
    found_uploads=true
  done < <(tar -tzf "$backup_dir/uploads.tar.gz")
  [[ "$found_uploads" == true ]] || { echo "Upload archive is empty" >&2; exit 2; }
  rm -rf -- /var/lib/assembly-os/data/uploads
  tar --no-same-owner -C /var/lib/assembly-os/data -xzf "$backup_dir/uploads.tar.gz"
  chown -R 10001:10001 /var/lib/assembly-os/data/uploads
fi
"${compose[@]}" up -d backend
"${compose[@]}" up -d frontend bot caddy
