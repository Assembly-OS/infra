#!/usr/bin/env python3
"""Application-role PostgreSQL operations; never provision or control the server."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

CONTAINER = "infrastructure-postgres-postgres-1"


def client(settings, program, *arguments, **kwargs):
    names = {"PGHOST": "DB_HOST", "PGPORT": "DB_PORT", "PGDATABASE": "DB_NAME",
             "PGUSER": "DB_USER", "PGPASSWORD": "DB_PASSWORD"}
    env = dict(os.environ, **{k: settings[v] for k, v in names.items()})
    command = ["docker", "exec", "-i", "--user", "postgres"]
    for name in names:
        command += ["--env", name]
    # Values, especially PGPASSWORD, never appear in argv or logs.
    return subprocess.run(command + [CONTAINER, program, *arguments], env=env,
                          check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("check", "dump", "restore", "inventory"))
    parser.add_argument("--config", type=Path, default=Path("/etc/assembly-os/database.json"))
    parser.add_argument("--file", type=Path)
    parser.add_argument("--confirm-database")
    parser.add_argument("--require-restored", action="store_true")
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    if args.require_restored:
        try:
            marker = json.loads(Path('/var/lib/assembly-os/restore-verified').read_text())
        except (OSError, ValueError):
            raise SystemExit('Missing or invalid restore attestation') from None
        if (marker.get('project'), marker.get('database'), marker.get('role')) != ('assembly-os', config['DB_NAME'], config['DB_USER']):
            raise SystemExit('Restore attestation does not match the configured project identity')
    for key in ("DB_NAME", "DB_USER"):
        if not re.fullmatch(r"[a-z_][a-z0-9_]{0,62}", config[key]):
            raise SystemExit("Invalid database identity")
    if config["DB_USER"] in {"postgres", "assambleya"} or config["DB_NAME"] in {"postgres", "template0", "template1"}:
        raise SystemExit("A dedicated non-administrator application identity is required")
    network = json.loads(subprocess.check_output(["docker", "inspect", "--format", "{{json .NetworkSettings.Networks}}", CONTAINER]))
    if config["DB_NETWORK"] not in network:
        raise SystemExit("Shared database container is not attached to DB_NETWORK")
    result = client(config, "psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c",
                    "SELECT current_database(), current_user, rolsuper, rolcreatedb, rolcreaterole, "
                    "pg_get_userbyid(datdba)=current_user FROM pg_roles, pg_database "
                    "WHERE rolname=current_user AND datname=current_database();", capture_output=True, text=True)
    expected = f"{config['DB_NAME']}|{config['DB_USER']}|f|f|f|t"
    if result.stdout.strip() != expected:
        raise SystemExit("Database identity/privilege check failed")
    if args.operation == "check":
        print("Application database identity and network verified")
    elif args.operation == "inventory":
        # Counts only; no business data is returned. Also useful for source comparison.
        client(config, "psql", "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", input=
               "SELECT format('SELECT %L, count(*) FROM %I.%I;', tablename, schemaname, tablename) "
               "FROM pg_tables WHERE schemaname='public' ORDER BY tablename\n\\gexec\n", text=True)
    elif args.operation == "dump":
        if not args.file:
            parser.error("--file is required")
        with args.file.open("xb") as stream:
            args.file.chmod(0o600)
            client(config, "pg_dump", "--format=custom", "--no-owner", "--no-privileges", stdout=stream)
        with args.file.open("rb") as stream:
            client(config, "pg_restore", "--list", stdin=stream, stdout=subprocess.DEVNULL)
    else:
        if not args.file or args.confirm_database != config["DB_NAME"]:
            parser.error("restore requires --file and --confirm-database matching DB_NAME")
        with args.file.open("rb") as stream:
            client(config, "pg_restore", "--dbname", config["DB_NAME"], "--clean", "--if-exists",
                   "--no-owner", "--no-privileges", "--single-transaction", "--exit-on-error", stdin=stream)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError:
        raise SystemExit("Project database operation failed; no credentials have been printed")
