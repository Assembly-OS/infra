#!/usr/bin/env python3
"""Render root-only Docker env files without printing their values."""

from __future__ import annotations

import argparse
import os
import re
import stat
from pathlib import Path


HASH = re.compile(r"^scrypt\$[0-9a-f]{32}\$[0-9a-f]{128}$")
DOMAIN = re.compile(r"^[A-Za-z0-9.-]+$")
CSV_IDS = re.compile(r"^(?:[0-9]+(?:,[0-9]+)*)?$")
# The database password is carried inside DATABASE_URL, where ':', '@' and '/'
# would be read as URL structure instead of as characters of the password.
# Restricting it to unreserved characters removes the need to percent-encode.
PG_SECRET = re.compile(r"^[A-Za-z0-9._~-]+$")

# The application defaults to the `assambleya` database when DATABASE_URL is
# absent; the deployed cluster keeps that name so both agree.
PG_USER = "assambleya"
PG_DB = "assambleya"


def value(name: str, *, required: bool = True) -> str:
    result = os.environ.get(name, "")
    if required and not result:
        raise SystemExit(f"Required runtime setting is missing: {name}")
    if "\x00" in result or "\n" in result or "\r" in result:
        raise SystemExit(f"Runtime setting must be one line: {name}")
    if "'" in result:
        raise SystemExit(f"Runtime setting contains an unsupported quote: {name}")
    return result


def emit(path: Path, entries: dict[str, str]) -> None:
    path.write_text("".join(f"{key}='{item}'\n" for key, item in entries.items()), encoding="utf-8")
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--service", required=True, choices=("backend", "frontend", "bot"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    args.output.chmod(stat.S_IRWXU)

    auth_secret = value("AUTH_SECRET")
    notify_secret = value("BOT_NOTIFY_SECRET")
    postgres_password = value("POSTGRES_PASSWORD")
    admin_hash = value("ADMIN_PASSWORD_HASH")
    domain = value("APP_DOMAIN")
    admin_ids = value("ADMIN_IDS", required=False)
    dev_panel_enabled = value("DEV_PANEL_ENABLED", required=False) or "0"
    dev_panel_key = value("DEV_PANEL_KEY", required=False)

    if len(auth_secret.encode()) < 32:
        raise SystemExit("AUTH_SECRET must contain at least 32 bytes")
    if len(notify_secret.encode()) < 32:
        raise SystemExit("BOT_NOTIFY_SECRET must contain at least 32 bytes")
    if len(postgres_password.encode()) < 16:
        raise SystemExit("POSTGRES_PASSWORD must contain at least 16 bytes")
    if not PG_SECRET.fullmatch(postgres_password):
        raise SystemExit("POSTGRES_PASSWORD must use only unreserved URL characters")
    if not HASH.fullmatch(admin_hash):
        raise SystemExit("ADMIN_PASSWORD_HASH is not a supported scrypt hash")
    if not DOMAIN.fullmatch(domain) or ".." in domain:
        raise SystemExit("APP_DOMAIN is invalid")
    if not CSV_IDS.fullmatch(admin_ids):
        raise SystemExit("ADMIN_IDS must be a comma-separated list of numeric Telegram IDs")
    if dev_panel_enabled not in {"0", "1"}:
        raise SystemExit("DEV_PANEL_ENABLED must be 0 or 1")
    if dev_panel_enabled == "1" and len(dev_panel_key.encode()) < 32:
        raise SystemExit("DEV_PANEL_KEY must contain at least 32 bytes when enabled")

    common = {
        "NODE_ENV": "production",
        "DATABASE_URL": f"postgres://{PG_USER}:{postgres_password}@postgres:5432/{PG_DB}",
        "AUTH_SECRET": auth_secret,
        "ADMIN_LOGIN": value("ADMIN_LOGIN"),
        "ADMIN_PASSWORD_HASH": admin_hash,
        "BOT_NOTIFY_SECRET": notify_secret,
        "BOT_NOTIFY_URL": "http://bot:8080/notify",
        "CRM_ADMIN_LOGINS": value("CRM_ADMIN_LOGINS", required=False),
        "NEXT_PUBLIC_TIME_ZONE": value("NEXT_PUBLIC_TIME_ZONE"),
        "PLATFORM_PUBLIC_URL": f"https://{domain}",
        "ANTHROPIC_API_KEY": value("ANTHROPIC_API_KEY", required=False),
        "DEV_PANEL_ENABLED": dev_panel_enabled,
    }
    if dev_panel_enabled == "1":
        common["DEV_PANEL_KEY"] = dev_panel_key
    emit(args.output / "backend.env", common)
    emit(args.output / "frontend.env", common)
    emit(
        args.output / "bot.env",
        {
            "APP_ENV": "production",
            "BOT_TOKEN": value("BOT_TOKEN", required=args.service == "bot"),
            "BOT_NOTIFY_SECRET": notify_secret,
            "PLATFORM_DB": "/data/assambleya.db",
            "PLATFORM_URL": f"https://{domain}",
            "WEBAPP_URL": f"https://{domain}",
            "PLATFORM_API": "http://backend:3000",
            "WEBAPP_HOST": "0.0.0.0",
            "WEBAPP_PORT": "8080",
            "ADMIN_IDS": admin_ids,
        },
    )
    emit(
        args.output / "postgres.env",
        {
            "POSTGRES_PASSWORD": postgres_password,
            "POSTGRES_USER": PG_USER,
            "POSTGRES_DB": PG_DB,
        },
    )
    emit(args.output / "caddy.env", {"APP_DOMAIN": domain, "ACME_EMAIL": value("ACME_EMAIL")})
    retention = value("BACKUP_RETENTION_DAYS")
    if not retention.isdigit() or not 1 <= int(retention) <= 365:
        raise SystemExit("BACKUP_RETENTION_DAYS must be between 1 and 365")
    emit(args.output / "backup.env", {"BACKUP_RETENTION_DAYS": retention})


if __name__ == "__main__":
    main()
