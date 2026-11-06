import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def fixture():
    return {"AUTH_SECRET": "a" * 32, "BOT_NOTIFY_SECRET": "b" * 32,
            "ADMIN_PASSWORD_HASH": "scrypt$" + "a" * 32 + "$" + "b" * 128,
            "APP_DOMAIN": "assemblyos.uz", "ADMIN_LOGIN": "admin", "BOT_TOKEN": "fixture",
            "NEXT_PUBLIC_TIME_ZONE": "Asia/Tashkent", "ACME_EMAIL": "ops@example.com",
            "BACKUP_RETENTION_DAYS": "14", "DB_HOST": "postgres", "DB_PORT": "5432",
            "DB_NAME": "fixture_db", "DB_USER": "fixture_user", "DB_PASSWORD": "a:@/'$\\secret",
            "DB_NETWORK": "infrastructure_database", "INGRESS_NETWORK": "agrozanjir_web"}


class RuntimeTests(unittest.TestCase):
    def render(self, env, output, service="backend"):
        return subprocess.run([sys.executable, ROOT / "scripts/render-env.py", "--service", service,
                               "--output", output], env=env, capture_output=True, text=True)

    def test_all_services_encode_password_and_never_render_admin_settings(self):
        for service in ("backend", "frontend", "bot"):
            with self.subTest(service=service), tempfile.TemporaryDirectory() as folder:
                env = dict(os.environ, **fixture())
                result = self.render(env, folder, service)
                self.assertEqual(result.returncode, 0, result.stderr)
                content = Path(folder, "backend.env").read_text()
                url = content.split("DATABASE_URL='", 1)[1].split("'", 1)[0]
                parsed = urlsplit(url)
                self.assertEqual(unquote(parsed.password), env["DB_PASSWORD"])
                self.assertEqual(parsed.hostname, "postgres")
                self.assertEqual(parsed.path, "/fixture_db")
                self.assertEqual(json.loads(Path(folder, "database.json").read_text())["DB_USER"], "fixture_user")
                self.assertFalse(Path(folder, "postgres.env").exists())
                self.assertNotIn("POSTGRES_PASSWORD", content)
                self.assertEqual(result.stdout, "")
                self.assertNotIn(env["DB_PASSWORD"], result.stderr)

    def test_missing_and_invalid_database_settings_fail_without_secret_output(self):
        for name, value in (("DB_PORT", "0"), ("DB_NAME", "other;DROP"), ("DB_HOST", "x\nsecret"),
                            ("DB_USER", ""), ("DB_PASSWORD", ""), ("DB_PASSWORD", "secret\nline")):
            with self.subTest(name=name, value=value), tempfile.TemporaryDirectory() as folder:
                env = {**os.environ, **fixture(), name: value}
                result = self.render(env, folder)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("secret\nline", result.stderr)

    def test_db_password_is_forwarded_by_environment_only(self):
        db = module("project-db")
        settings = fixture()
        with patch.object(db.subprocess, "run") as run:
            db.client(settings, "pg_dump", "--format=custom")
        command = run.call_args.args[0]
        self.assertIn("infrastructure-postgres-postgres-1", command)
        self.assertNotIn(settings["DB_PASSWORD"], " ".join(command))
        self.assertEqual(run.call_args.kwargs["env"]["PGPASSWORD"], settings["DB_PASSWORD"])
        self.assertEqual(run.call_args.kwargs["env"]["PGUSER"], "fixture_user")

    def test_wrong_restore_attestation_is_rejected_before_database_access(self):
        db = module("project-db")
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder, "database.json")
            config.write_text(json.dumps(fixture()))
            read_text = Path.read_text

            def read(path, *args, **kwargs):
                if path.as_posix() == "/var/lib/assembly-os/restore-verified":
                    return json.dumps({"project": "assembly-os", "database": "wrong_db", "role": "fixture_user"})
                return read_text(path, *args, **kwargs)

            with patch.object(db.Path, "read_text", read), patch.object(db.subprocess, "check_output") as inspect:
                with patch.object(sys, "argv", ["project-db.py", "check", "--config", str(config), "--require-restored"]):
                    with self.assertRaisesRegex(SystemExit, "attestation"):
                        db.main()
                inspect.assert_not_called()

    @unittest.skipUnless(shutil.which("docker"), "Docker Compose CLI is unavailable")
    def test_resolved_compose_uses_rendered_settings_without_database_service_or_ports(self):
        with tempfile.TemporaryDirectory() as folder:
            env = dict(os.environ, **fixture())
            self.assertEqual(self.render(env, folder).returncode, 0)
            compose = Path(folder, "compose.yaml")
            compose.write_text((ROOT / "compose.yaml").read_text().replace(
                "/etc/assembly-os/", Path(folder).as_posix() + "/"))
            command = ["docker", "compose"]
            for service in ("backend", "frontend", "bot"):
                command += ["--env-file", str(ROOT / "apps" / service / "image.env")]
            result = subprocess.run(command + ["-f", str(compose), "config", "--format", "json"],
                                    env=env, capture_output=True, text=True, check=True)
            config = json.loads(result.stdout)
            self.assertNotIn("postgres", config["services"])
            self.assertFalse(any(item.get("ports") for item in config["services"].values()))
            for key in ("assembly-os-backend", "assembly-os-frontend"):
                settings = config["services"][key]["environment"]
                self.assertEqual(settings["DB_NAME"], "fixture_db")
                self.assertEqual(unquote(urlsplit(settings["DATABASE_URL"]).password), env["DB_PASSWORD"])
                self.assertIn("database", config["services"][key]["networks"])


class MediaTests(unittest.TestCase):
    def backup(self, root, member="uploads/photo.txt", kind=None):
        (root / "database.dump").write_bytes(b"fixture")
        (root / "identity.json").write_text(json.dumps({"project": "assembly-os"}))
        with tarfile.open(root / "uploads.tar.gz", "w:gz") as archive:
            info = tarfile.TarInfo(member)
            if kind:
                info.type = kind
                info.linkname = "/etc/passwd"
                archive.addfile(info)
            else:
                info.size = 3
                archive.addfile(info, io.BytesIO(b"new"))
        with (root / "SHA256SUMS").open("w") as sums:
            for name in ("database.dump", "identity.json", "uploads.tar.gz"):
                sums.write(hashlib.sha256((root / name).read_bytes()).hexdigest() + "  " + name + "\n")

    def test_media_restore_retains_previous_files(self):
        media = module("restore-media")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder, "backup"); root.mkdir()
            target = Path(folder, "data"); (target / "uploads").mkdir(parents=True)
            (target / "uploads/old.txt").write_text("old")
            self.backup(root)
            # Do not alter ownership in this local test.
            with patch.object(media.sys, "platform", "win32"):
                media.apply(root, target)
            self.assertEqual((target / "uploads/photo.txt").read_text(), "new")
            self.assertEqual(len(list(target.glob("uploads.before-*/old.txt"))), 1)

    def test_traversal_links_and_devices_are_rejected_before_restore(self):
        media = module("restore-media")
        for member, kind in (("uploads/../../etc/passwd", None), ("/uploads/x", None),
                             ("uploads/link", tarfile.SYMTYPE), ("uploads/device", tarfile.CHRTYPE),
                             ("uploads/hard", tarfile.LNKTYPE), ("uploads\\..\\x", None)):
            with self.subTest(member=member), tempfile.TemporaryDirectory() as folder:
                root = Path(folder); self.backup(root, member, kind)
                with self.assertRaises(ValueError):
                    media.validate(root)

    def test_corrupt_dump_is_rejected(self):
        media = module("restore-media")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); self.backup(root)
            (root / "database.dump").write_bytes(b"corrupted")
            with self.assertRaises(ValueError):
                media.validate(root)

    def test_wrong_project_is_rejected_even_with_valid_checksums(self):
        media = module("restore-media")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); self.backup(root)
            identity = root / "identity.json"
            old_hash = hashlib.sha256(identity.read_bytes()).hexdigest()
            identity.write_text(json.dumps({"project": "another-project"}))
            new_hash = hashlib.sha256(identity.read_bytes()).hexdigest()
            sums = root / "SHA256SUMS"
            sums.write_text(sums.read_text().replace(old_hash, new_hash))
            with self.assertRaisesRegex(ValueError, "another project"):
                media.validate(root)


if __name__ == "__main__":
    unittest.main()
