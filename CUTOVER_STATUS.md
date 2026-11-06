# Data transfer status — 2026-11-07 02:08 Asia/Tashkent

The owner approved the maintenance window and data transfer/restore. That phase is complete. Application startup migrations, deployment, shared-edge reload, DNS and certificate issuance have not been performed.

## Verified restore

- Source: `89.167.121.228`, PostgreSQL 17.11, database/role `assambleya`.
- Target: existing shared PostgreSQL 18.1 at `65.108.142.153`, database `assembly_os_db`, role `assembly_os_user`.
- 35 public tables and 835 rows: every row count and sorted row-content fingerprint matches.
- All 28 sequences match `last_value` and `is_called`.
- Column definitions, defaults, nullability, indexes, 35 primary keys, 64 foreign keys and 4 unique constraints match.
- PostgreSQL 18 records NOT NULL constraints separately in `pg_constraint`. Its 211 entries were independently matched to the source's non-null columns and checked as validated/enforced. This is the documented [PostgreSQL 18 catalog change](https://www.postgresql.org/docs/18/release-18.html), not a missing-source-constraint discrepancy.
- All 52 upload files match byte counts and SHA-256 hashes: 13,786,915 bytes total. Upload directories also match.
- The preserved legacy SQLite file matches its exported checksum and passed SQLite integrity checking.
- All restored public tables belong to `assembly_os_user`.
- Existing shared-server container IDs/start times and database identities/owners are unchanged. Other application containers remain running; the shared PostgreSQL container was not restarted.
- Root-only `/var/lib/assembly-os/restore-verified` attests the verified project/database/role and cutover ID.

## Retained recovery copies

The old PostgreSQL data directory, old uploads, old SQLite data and all existing Docker volumes remain intact. No old database or volume was deleted.

Project backup directories (root-only):

- Old host: `/var/backups/assembly-os/manual/cutover-20261106T210000Z`.
- New host: `/var/backups/assembly-os/manual/cutover-20261106T210000Z` (transferred final source snapshot).
- New host: `/var/backups/assembly-os/manual/before-restore-20261106T210604Z` (pre-restore target snapshot).
- New host: `/var/backups/assembly-os/manual/restored-cutover-20261106T210000Z` (fresh verified backup after restoration).

Checksums passed before transfer, after local transfer and after target transfer. The fresh target backup also passed checksum and archive/SQLite validation. A private, ACL-restricted local source copy and detailed hash audits were retained outside the Git checkout; no critical backup contents, row values, upload filenames or credentials are committed here.

## Current service state and next action

Old Assembly backend, frontend and bot are stopped. Old PostgreSQL and Caddy remain healthy. No Assembly application containers have been started on the new host. Both project backup timers remain inactive during maintenance. Assembly is unavailable while awaiting cutover; do not restart old writers or run both bots.

Next requires approval: start the new backend (including its existing startup schema/legacy-import hook), deploy frontend, integrate the prepared Assembly site into the existing shared edge, issue/verify origin TLS, switch DNS, and start the new bot. Keep deployment disabled until that approval. Verify a new-host backup and enable only this project's backup timer before reopening public writes. Follow MIGRATION.md for ordering and rollback constraints.
