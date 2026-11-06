# Verification — 2026-11-07

All production inspections were read-only. Preparation performed no deployment, database mutation, restore, migration, service restart, DNS change, certificate issuance or volume deletion. The owner subsequently approved committing and pushing the prepared infrastructure changes to main; production rollout remains unapproved. Push-triggered deployment jobs are explicitly disabled during migration; manual deployment also requires the deployment gate.

## Executed checks

| Check | Result |
| --- | --- |
| Python runtime/media safety tests | 9 passed. Includes all three service renders, password punctuation/URL encoding, invalid settings, secret forwarding without argv exposure, resolved Compose env files, no PostgreSQL service or published ports, archive traversal/link/device rejection, checksum/project identity checks, preserving old media and rejecting a mismatched restore attestation. |
| Synthetic local PostgreSQL 17 -> 18 rehearsal | Passed, including the final database-owner check. Custom dump/transactional restore as non-admin application roles preserved row counts, Unicode text, binary values, foreign keys, ownership and sequence state. An unrelated fixture database was unchanged and wrong-target confirmation was rejected. Only dedicated local test containers/network were created/removed; no production data or existing volumes were used/deleted. |
| Python compile check | Passed for infra scripts. |
| Docker Compose validation | Passed with immutable image manifests and external network settings. Both unresolved production-file validation and fully resolved synthetic runtime files passed. |
| ShellCheck v0.11.0 | Passed for project shell scripts. |
| actionlint v1.7.12 | Passed, including its installed ShellCheck integration for workflow shell snippets. |
| Caddy internal proxy configuration | Valid with the project's pinned Caddy image. No published ports, listener startup or certificate issuance during validation. |
| Shared-edge site configuration | Valid standalone. Also validated a local merge into the actual inspected shared-edge Caddyfile and YouthCapital include using the exact production edge image digest. Existing formatting/header warnings were non-fatal; unrelated site configuration was preserved. |
| Semgrep 1.179.0 | 3 deployment security rules, 9 script files, 0 findings. Rules check prohibited host reconfiguration, cluster provisioning/dumps and PostgreSQL lifecycle commands. This is a focused deployment scan, not a general application security audit. |
| Gitleaks v8.30.1 | Redacted checkout scan passed, 0 leaks. |
| Trivy 0.69.3 | Secret scan passed. The attempted vulnerability/misconfiguration scan reported no supported dependency/config files in this infra checkout, so no vulnerability or Compose-security coverage is claimed from that scan. CI uses the supported secret scanner plus separate deployment rules and Compose validation. |
| git diff --check | Passed. Line-ending conversion notices for Markdown/Git metadata are not whitespace errors. Shell/Python/YAML/systemd/Caddy artifacts have LF rules. |
| Component repository status | Backend, frontend and telegrambot are clean after their initial fast-forward updates; migration edits are confined to infra. No application dependency or image manifest was changed. |

## Server evidence

The old backend/frontend use database `assambleya`, role `assambleya`, PostgreSQL 17.11. The owner confirmed the destination as `assembly_os_db`, role `assembly_os_user`, on the existing shared PostgreSQL 18.1 container. Metadata shows the destination is owned by that role, currently has no public tables, and the role has LOGIN without superuser/CREATEDB/CREATEROLE. Application-password authentication is still to be checked using the prod secret during approved bootstrap.

The new server has no existing Assembly OS Compose project or project storage. Existing shared database/ingress networks are present. Shared edge owns 80/443; the prepared app exposes no host ports and uses unique service names on external networks.

DNS resolves `assemblyos.uz` to the old server; public HTTPS returned 200. New-origin TLS with the correct SNI failed. Cloudflare dashboard settings and certificate issuance were not changed or verified. The approved issuance/verification procedure is in MIGRATION.md.

## Still pending approval/access

- Configure the protected GitHub prod environment, its secrets/variables and repository deployment gate. GitHub CLI authentication failed; connected GitHub tools do not expose environment-secret management. No GitHub settings were written and no password was retrieved.
- Execute CI on GitHub after the separately approved main-branch push.
- Bootstrap target project storage, final old-server write freeze/export, secure transfer, project-only restore, and comparison of real data/media/sequences.
- Approve backend startup migrations, application deployment, shared-edge source/site reload, DNS/Cloudflare changes and certificate issuance. Keep old critical data and volumes intact.
- End-to-end production smoke tests and actual backup/restore recovery verification. Synthetic test success does not substitute for comparing restored critical production data.

See README.md for exact GitHub settings and MIGRATION.md for rollout and rollback order.
