"""Synthetic local PostgreSQL 17 -> 18 dump/restore; never contacts a remote host."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
NETWORK = "assembly-os-local-migration-rehearsal"
NAMES = ["assembly-os-local-rehearsal-17", "assembly-os-local-rehearsal-18"]


def docker(*args, **kwargs):
    return subprocess.run(["docker", *args], check=True, capture_output=True, **kwargs)


def sql(container, database, query):
    return docker("exec", container, "psql", "-X", "-U", "postgres", "-d", database,
                  "-At", "-v", "ON_ERROR_STOP=1", "-c", query, text=True).stdout.strip()


def main():
    # Refuse remote Docker contexts, including DOCKER_HOST overrides.
    endpoint = docker("context", "inspect", "--format", "{{.Endpoints.docker.Host}}", text=True).stdout.strip()
    if os.environ.get("DOCKER_HOST") or not endpoint.startswith(("npipe://", "unix://")):
        raise SystemExit("Rehearsal requires a local Docker daemon")
    spec = importlib.util.spec_from_file_location("project_db", ROOT / "scripts/project-db.py")
    db = importlib.util.module_from_spec(spec); spec.loader.exec_module(db)
    created = []
    docker("network", "create", NETWORK)
    try:
        for name, image, role in zip(NAMES, ("postgres:17-alpine", "postgres:18-trixie"), ("source_user", "target_user")):
            docker("run", "-d", "--name", name, "--network", NETWORK,
                   "--tmpfs", "/var/lib/postgresql", "--tmpfs", "/var/lib/postgresql/data",
                   "--tmpfs", "/test-data", "-e", "PGDATA=/test-data",
                   "-e", "POSTGRES_PASSWORD=synthetic-local-admin", image)
            created.append(name)
            for _ in range(60):
                try:
                    sql(name, "postgres", "SELECT 1"); break
                except subprocess.CalledProcessError:
                    time.sleep(1)
            else:
                raise RuntimeError("Test PostgreSQL did not become ready")
            sql(name, "postgres", f"CREATE ROLE {role} LOGIN PASSWORD 'synthetic-local-app';")
            sql(name, "postgres", f"CREATE DATABASE project_data OWNER {role};")
        source, target = NAMES
        sql(source, "project_data", "SET ROLE source_user; CREATE TABLE parent(id bigserial PRIMARY KEY, value text); "
            "CREATE TABLE child(id bigserial PRIMARY KEY, parent_id bigint REFERENCES parent(id), content bytea); "
            "INSERT INTO parent(value) VALUES ('critical fixture'), ('Ўзбекистон'); "
            "INSERT INTO child(parent_id, content) VALUES (2, decode('00ff', 'hex')); "
            "SELECT setval('parent_id_seq', 100);")
        sql(target, "postgres", "CREATE DATABASE unrelated_fixture;")
        sql(target, "unrelated_fixture", "CREATE TABLE sentinel(value text); INSERT INTO sentinel VALUES ('untouched');")
        base = {"DB_HOST": "127.0.0.1", "DB_PORT": "5432", "DB_NAME": "project_data",
                "DB_USER": "source_user", "DB_PASSWORD": "synthetic-local-app", "DB_NETWORK": NETWORK}
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder, "database.json"); dump = Path(folder, "database.dump")
            config.write_text(json.dumps(base))
            db.CONTAINER = source
            with_args = lambda *a: ["project-db.py", *a, "--config", str(config)]
            sys.argv = with_args("dump", "--file", str(dump)); db.main()
            db.CONTAINER = target; base["DB_USER"] = "target_user"
            config.write_text(json.dumps(base))
            sys.argv = with_args("restore", "--file", str(dump), "--confirm-database", "project_data"); db.main()
            assert sql(target, "project_data", "SELECT count(*) FROM parent;") == "2"
            assert sql(target, "project_data", "SELECT value FROM parent WHERE id=2;") == "Ўзбекистон"
            assert sql(target, "project_data", "SELECT count(*) FROM pg_constraint WHERE contype='f';") == "1"
            assert sql(target, "project_data", "SELECT encode(content,'hex') FROM child;") == "00ff"
            assert sql(target, "project_data", "SELECT nextval('parent_id_seq');") == "101"
            assert sql(target, "project_data", "SELECT tableowner FROM pg_tables WHERE tablename='parent';") == "target_user"
            assert sql(target, "unrelated_fixture", "SELECT value FROM sentinel;") == "untouched"
            # Wrong confirmation must fail before a restore command is issued.
            sys.argv = with_args("restore", "--file", str(dump), "--confirm-database", "unrelated_fixture")
            try:
                db.main()
            except SystemExit as error:
                assert error.code != 0
            else:
                raise AssertionError("Wrong target confirmation accepted")
        print("PASS: PostgreSQL 17 -> 18, application-role ownership, rows, binary media references, sequences, unrelated DB and wrong-target guard")
    finally:
        for name in reversed(created):
            docker("rm", "-f", name)
        docker("network", "rm", NETWORK)


if __name__ == "__main__":
    main()
