# Assembly OS on the dedicated Docker host

This repository owns Assembly OS deployment only. Application repositories publish immutable GHCR digests into `apps/{backend,frontend,bot}/image.env`; this repository deploys them. All bootstrap/deploy jobs use the protected GitHub **prod** environment and the existing `assembly-os-production` concurrency group.

## Architecture

- Host: `deploy@65.108.142.153`, passwordless sudo for project operations.
- Compose project: `assembly-os`; private network `assembly-os_app`.
- `assembly-os-backend` and `assembly-os-frontend` join existing external `infrastructure_database`. Both applications read PostgreSQL; both need database connectivity. Generic `backend`/`frontend` aliases exist only on the private project network.
- Existing PostgreSQL: `infrastructure-postgres-postgres-1`, DNS `postgres:5432`. No PostgreSQL service, cluster initialization, role creation, administrator password, PostgreSQL volume or host port is managed here.
- Preserve the Telegram bot and `/data/assambleya.db` legacy store, plus `/data/uploads`. There is no Redis service in this project to migrate.
- `assembly-os-proxy` preserves the project Caddy routing on internal port 8080, joins existing `agrozanjir_web`, and publishes no host ports. Only the existing `agrozanjir-caddy-1` owns 80/443 and certificates. Its Assembly site is prepared in `edge/site.caddy`; applying it requires separate approval. It overwrites a project client-IP header, which the internal proxy forwards for application rate limiting.
- Project paths: `/opt/assembly-os`, `/etc/assembly-os`, `/var/lib/assembly-os`, `/var/backups/assembly-os`. Numeric data owner is UID/GID 10001; no shared host group/account changes.

Read [MIGRATION.md](MIGRATION.md) before rollout. Starting the backend **runs its existing schema migration and legacy-import startup hook**. Do not start it before restoration, verification, and explicit approval.

## GitHub settings

The repository previously used `production`. Create **prod**, restrict it to `main`, require an approving reviewer, and migrate existing application settings to it before enabling deployment. Keep old workflows/runs from deploying during cutover. GitHub settings have not been changed by this local migration.

Set repository-level Actions variable `DEPLOY_ENABLED=false` (or leave absent). Deployments are manual (`workflow_dispatch`) during migration; pushes run checks only. The deploy job also checks this gate before selecting its environment; this particular gate must be a **repository variable**, not a prod environment variable. Set it to `true` only after the approved restore. Environment reviewers remain required for future deployments. Pushing these changes with the gate absent/false cannot deploy application services.

**prod environment secrets**:

| Setting | Purpose |
| --- | --- |
| `DB_USER` | `assembly_os_user`, the confirmed pre-created application role |
| `DB_PASSWORD` | That role's existing application password; never the PostgreSQL administrator password |
| `VPS_HOST` | `65.108.142.153` (existing variable name retained) |
| `VPS_SSH_KEY` | Dedicated deploy SSH private key; do not paste it into logs |
| `VPS_SSH_HOST_KEY` | Complete pinned known_hosts entry, fingerprint independently verified |
| `GHCR_PULL_TOKEN` | Read-only GHCR access |
| `AUTH_SECRET` | Preserve existing value, at least 32 bytes |
| `ADMIN_PASSWORD_HASH` | Preserve existing scrypt hash |
| `BOT_NOTIFY_SECRET` | Preserve existing value, at least 32 bytes |
| `BOT_TOKEN` | Preserve existing token; required for bot deployment |
| `ANTHROPIC_API_KEY` | Existing optional application credential |
| `DEV_PANEL_KEY` | Only if deliberately enabling the dev panel |

Do not configure `POSTGRES_PASSWORD`, a cluster password, or a new database administrator credential. Password punctuation is URL-encoded for the existing `DATABASE_URL` application interface. `DB_HOST`, `DB_PORT`, `DB_NAME` and `DB_USER` are also forwarded explicitly to backend/frontend env files. Root-only `database.json` lets maintenance tools use the same application role, passing credentials through process environment rather than command arguments. Runtime files are mode 0600, configuration directories mode 0700.

**prod environment variables**:

| Setting | Value |
| --- | --- |
| `DB_HOST` | `postgres` |
| `DB_PORT` | `5432` |
| `DB_NAME` | `assembly_os_db` (confirmed existing project database) |
| `DB_NETWORK` | `infrastructure_database` |
| `INGRESS_NETWORK` | `agrozanjir_web` |
| `VPS_USERNAME` | `deploy` |
| `VPS_SSH_PORT` | `22` |
| `DEPLOY_ROOT` | `/opt/assembly-os` |
| `APP_DOMAIN` | `assemblyos.uz` |
| `ACME_EMAIL` | Existing certificate contact, used when reviewing shared-edge issuance |
| `GHCR_USERNAME` | Owner of the pull token |
| `BACKUP_RETENTION_DAYS` | `14` |
| `ADMIN_LOGIN` | Preserve existing value |
| `ADMIN_IDS` | Preserve Telegram administrator IDs |
| `CRM_ADMIN_LOGINS` | Preserve existing value |
| `NEXT_PUBLIC_TIME_ZONE` | `Asia/Tashkent` |
| `DEV_PANEL_ENABLED` | `0` unless explicitly required |

All three deploy entry points inherit secrets into `_deploy.yml`; it renders the same DB/network configuration for every service deployment. Bootstrap renders the same settings so the database can be restored before the first application start. Application build workflows do not connect to the database and do not need database credentials. Their existing `INFRA_REPO_TOKEN`, digest promotion, SBOM/provenance and image security checks remain unchanged.

## Bootstrap and maintenance

`Server bootstrap` prepares project directories, runtime files, model downloads with SHA-256 verification, and the project's backup scripts/systemd units. It checks existing Docker/Compose and application-role connectivity. It does **not** install packages, upgrade APT, reboot, configure Docker, restart Docker/PostgreSQL, alter firewall/network/SSH/fail2ban, create accounts, or provision any database. Missing prerequisites are reported for the host operator to resolve separately.

The backup timer is enabled only after `/var/lib/assembly-os/restore-verified` exists. Bootstrap and deployment never create that marker. An operator creates this JSON attestation after comparing restored data and approving startup (format in MIGRATION.md); deployment rejects a different database/role. Deployment fails closed without it.

`assembly-os-backup scheduled|predeploy|manual ID` saves only the configured application database, uploads, and a consistent SQLite legacy copy, with checksums and identity metadata. The PostgreSQL client runs inside the existing shared database container using TCP and the application role; no server service is started. Scheduled backups are online database snapshots; database/media cross-consistency requires a write freeze for the final cutover export. Only scheduled backups expire automatically. Manual/cutover and predeploy snapshots are retained until an operator archives them. Critical data backups are no longer uploaded to GitHub Actions artifacts.

`assembly-os-restore BACKUP_DIR DB_NAME --confirm-project-restore` requires all project writers and the project backup timer already stopped, validates checksums and media paths before restoring, takes a target backup first, and restores in one PostgreSQL transaction using the application role. It does not stop/start any services. Old uploads/legacy SQLite are renamed alongside the restored data, not deleted. Archive links, devices and traversal paths are rejected. It never restores a cluster, users, another database, Docker volumes or PostgreSQL files. If restoration fails, keep writers stopped and recover explicitly; image rollback cannot undo schema/data changes.

For the first cutover, use `scripts/export-old.sh` on the old host after the approved write freeze. It produces the same custom-archive format expected by the new restore script. Historical `assambleya.sql.gz` backups remain untouched but require a separately reviewed conversion/recovery procedure; they are not accepted by this new restore helper.

## Local checks

```sh
python -m unittest discover -s tests -v
python tests/postgres_rehearsal.py   # synthetic data, LOCAL Docker only, PostgreSQL 17 -> 18
shellcheck --external-sources scripts/*.sh
actionlint
DB_NETWORK=infrastructure_database INGRESS_NETWORK=agrozanjir_web \
  docker compose --env-file apps/backend/image.env --env-file apps/frontend/image.env \
  --env-file apps/bot/image.env -f compose.yaml config --no-env-resolution --quiet
```

`checks.yml` runs the safety tests, isolated database rehearsal, ShellCheck, workflow lint, Compose/Caddy validation and Semgrep deployment rules and Trivy secret scanning. Actual shared-role authentication, production restoration, backend startup migrations, shared-edge reload and certificate issuance are rollout checks requiring approval. See [VERIFICATION.md](VERIFICATION.md) for executed checks and limitations.
