#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
backup_dir="${1:-}"
database="${2:-}"
[[ "${3:-}" == --confirm-project-restore ]] || {
  echo "Usage: assembly-os-restore /var/backups/assembly-os/<kind>/<id> DB_NAME --confirm-project-restore" >&2
  exit 2
}
backup_dir="$(readlink -f -- "$backup_dir")"
[[ "$backup_dir" == /var/backups/assembly-os/* && -f "$backup_dir/SHA256SUMS" && -f "$backup_dir/database.dump" ]] || exit 2
# The operator stops writers after approval. This script never stops/restarts services.
for service in backend frontend bot assembly-os-backend assembly-os-frontend; do
  [[ -z "$(docker ps -q --filter label=com.docker.compose.project=assembly-os --filter "label=com.docker.compose.service=$service")" ]] || { echo "Stop $service first" >&2; exit 2; }
done
python3 /usr/local/sbin/assembly-os-restore-media "$backup_dir" --validate
/usr/local/sbin/assembly-os-backup manual "before-restore-$(date -u +%Y%m%dT%H%M%SZ)"
/usr/local/sbin/assembly-os-project-db restore --file "$backup_dir/database.dump" --confirm-database "$database"
python3 /usr/local/sbin/assembly-os-restore-media "$backup_dir" --apply
echo "Restored project data. Verify counts, sequences and media before starting services."
