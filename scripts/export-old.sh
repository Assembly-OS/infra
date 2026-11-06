#!/usr/bin/env bash
# Execute on the OLD host only, after an approved write freeze.
set -Eeuo pipefail
umask 077
destination="${1:-}"
[[ "$destination" =~ ^/var/backups/assembly-os/manual/[A-Za-z0-9_-]+$ ]] || exit 2
[[ ! -e "$destination" ]] || { echo "Destination already exists" >&2; exit 2; }
for service in backend frontend bot; do
  [[ -z "$(docker ps -q --filter label=com.docker.compose.project=assembly-os --filter "label=com.docker.compose.service=$service")" ]] || {
    echo "Stop all Assembly OS writers before exporting" >&2; exit 2;
  }
done
install -d -m 0700 "$destination"
docker exec assembly-os-postgres-1 pg_dump -U assambleya -d assambleya \
  --format=custom --no-owner --no-privileges > "$destination/database.dump"
docker exec -i assembly-os-postgres-1 pg_restore --list < "$destination/database.dump" >/dev/null
printf '{"project":"assembly-os","database":"assambleya","role":"assambleya"}\n' > "$destination/identity.json"
# Preserve the full current uploads tree; never copy a live PostgreSQL data directory.
tar --numeric-owner -C /var/lib/assembly-os/data -czf "$destination/uploads.tar.gz" uploads
python3 - "$destination" <<'PYTHON'
import pathlib, sqlite3, sys
source = pathlib.Path('/var/lib/assembly-os/data/assambleya.db')
if source.exists():
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as old:
        with sqlite3.connect(str(pathlib.Path(sys.argv[1], 'assambleya.db'))) as new:
            old.backup(new)
            assert new.execute('PRAGMA quick_check').fetchone() == ('ok',)
PYTHON
# Inventory includes every public table and can be compared after restoration.
docker exec -i assembly-os-postgres-1 psql -X -U assambleya -d assambleya -At -v ON_ERROR_STOP=1 <<'SQL' > "$destination/counts.tsv"
SELECT format('SELECT %L, count(*) FROM %I.%I;', tablename, schemaname, tablename)
FROM pg_tables WHERE schemaname='public' ORDER BY tablename
\gexec
SQL
(cd "$destination"; sha256sum -- database.dump identity.json uploads.tar.gz counts.tsv > SHA256SUMS
  if [[ -f assambleya.db ]]; then sha256sum assambleya.db >> SHA256SUMS; fi)
echo "Export complete. Keep writers stopped until cutover or explicit rollback."
