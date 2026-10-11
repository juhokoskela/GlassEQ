import base64
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import time
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
BUILD_SETTINGS = "VERSION BUILD RELEASE_CHANNEL ARCH RELEASE_LABEL DRY_RUN SIGN_IDENTITY ENABLE_HARDENED_RUNTIME NOTARIZE NOTARY_PROFILE BUILD_DIR ENTITLEMENT_PUBLIC_KEYS_FILE".split()
PRODUCTION_SIGNING = ("SIGN_IDENTITY=Developer ID Application: Example",
                      "ENABLE_HARDENED_RUNTIME=1", "NOTARIZE=1", "NOTARY_PROFILE=example")


class ReleaseChannelTests(unittest.TestCase):
    def dry_run(self, *arguments):
        environment = {key: value for key, value in os.environ.items() if key not in BUILD_SETTINGS}
        return subprocess.run(
            [str(ROOT / "Scripts/build-release-app.sh"), "DRY_RUN=1", *arguments],
            env=environment, capture_output=True, text=True,
        )

    def test_default_beta_matches_the_app_label(self):
        with (ROOT / "Sources/GlassEQApp/Info.plist").open("rb") as source:
            label = plistlib.load(source)["GlassEQReleaseLabel"]
        result = self.dry_run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Channel: beta\n", result.stdout)
        self.assertIn("Signing: ad hoc\n", result.stdout)
        self.assertIn(f"GlassEQ-{label}-macos26-arm64.zip", result.stdout)

    def test_explicit_prerelease_channels(self):
        for channel in ("alpha", "beta"):
            for version, suffix in (("0.9.3", "0.9.3"), ("1.2.0", "1.2")):
                with self.subTest(channel=channel, version=version):
                    result = self.dry_run(f"RELEASE_CHANNEL={channel}", f"VERSION={version}")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"Channel: {channel}\n", result.stdout)
                    self.assertIn(f"GlassEQ-{channel}-{suffix}-macos26-arm64.zip", result.stdout)

    def test_prerelease_signing_and_architecture_requirements(self):
        for channel in ("alpha", "beta"):
            for argument in ("ARCH=x86_64", "SIGN_IDENTITY=Developer ID Application: Example",
                             "ENABLE_HARDENED_RUNTIME=1", "NOTARIZE=1", "NOTARY_PROFILE=example"):
                with self.subTest(channel=channel, argument=argument):
                    result = self.dry_run(f"RELEASE_CHANNEL={channel}", argument)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"{channel} builds", result.stderr)

    def write_keys_file(self, directory, content):
        path = Path(directory) / "keys.json"
        path.write_text(content)
        return f"ENTITLEMENT_PUBLIC_KEYS_FILE={path}"

    def test_production_requires_signing_and_notarization(self):
        with tempfile.TemporaryDirectory() as directory:
            keys = self.write_keys_file(directory, json.dumps({"k1": base64.b64encode(bytes(32)).decode()}))
            required = (*PRODUCTION_SIGNING, keys)
            result = self.dry_run("RELEASE_CHANNEL=production", "VERSION=1.2.3", *required)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Channel: production\n", result.stdout)
            self.assertIn("GlassEQ-production-1.2.3-macos26-arm64.zip", result.stdout)
            self.assertIn("GlassEQ-production-1.2.3-macos26-arm64.dmg", result.stdout)
            self.assertIn("Licensing: embedded public verification keys", result.stdout)
            self.assertNotIn(directory, result.stdout)
            for omitted in required:
                with self.subTest(omitted=omitted):
                    result = self.dry_run("RELEASE_CHANNEL=production", *(item for item in required if item != omitted))
                    self.assertNotEqual(result.returncode, 0)

    def test_entitlement_public_keys_file_is_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            valid_key = base64.b64encode(bytes(32)).decode()
            for content in ("not json", "{}", "[]", json.dumps({"k1": "short"}), json.dumps({"k1": 5}),
                            json.dumps({"k1": valid_key + " "}), json.dumps({"k1": valid_key + "\n"}),
                            json.dumps({"key one": valid_key}), json.dumps({"": valid_key}),
                            json.dumps({"k1": base64.b64encode(bytes(33)).decode()})):
                with self.subTest(content=content):
                    result = self.dry_run("RELEASE_CHANNEL=production", *PRODUCTION_SIGNING,
                                          self.write_keys_file(directory, content))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("ENTITLEMENT_PUBLIC_KEYS_FILE", result.stderr)
            result = self.dry_run("RELEASE_CHANNEL=production", *PRODUCTION_SIGNING,
                                  f"ENTITLEMENT_PUBLIC_KEYS_FILE={Path(directory) / 'missing.json'}")
            self.assertNotEqual(result.returncode, 0)
            valid = self.write_keys_file(directory, json.dumps({"k1": base64.b64encode(bytes(32)).decode()}))
            result = self.dry_run("RELEASE_CHANNEL=beta", valid)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Licensing: embedded public verification keys", result.stdout)

    def test_prerelease_builds_report_unrestricted_licensing(self):
        result = self.dry_run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Licensing: none (unrestricted beta build)\n", result.stdout)
        self.assertIn("GlassEQ-beta-", result.stdout)

    def test_custom_label_and_invalid_channel(self):
        result = self.dry_run("RELEASE_CHANNEL=beta", "RELEASE_LABEL=beta-preview")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("GlassEQ-beta-preview-macos26-arm64.zip", result.stdout)
        self.assertNotEqual(self.dry_run("RELEASE_CHANNEL=unknown").returncode, 0)


class ReleaseArtifactTests(unittest.TestCase):
    def functions(self, *names):
        source = (ROOT / "Scripts/build-release-app.sh").read_text()
        definitions = []
        for name in names:
            match = re.search(rf"^{name}\(\) ([{{(])$", source, re.MULTILINE)
            self.assertIsNotNone(match, name)
            end = "}" if match[1] == "{" else ")"
            tail = source[match.start():]
            finish = re.search(rf"^{re.escape(end)}$", tail, re.MULTILINE)
            definitions.append(tail[:finish.end()])
        return "\n".join(definitions) + "\n"

    def test_embedding_uses_the_validated_keys_even_if_the_source_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            keys = Path(directory) / "keys.json"
            info = Path(directory) / "Info.plist"
            expected = {"fixture": base64.b64encode(bytes(32)).decode()}
            keys.write_text(json.dumps(expected))
            info.write_bytes(plistlib.dumps({}))
            script = self.functions("fail", "validate_entitlement_public_keys_file", "embed_entitlement_public_keys")
            script += 'ENTITLEMENT_PUBLIC_KEYS_INFO_KEY=GlassEQEntitlementPublicKeys; validate_entitlement_public_keys_file "$1"; echo invalid > "$1"; embed_entitlement_public_keys "$2"'
            subprocess.run(["bash", "-eu", "-c", script, "test", str(keys), str(info)], check=True)
            self.assertEqual(plistlib.loads(info.read_bytes())["GlassEQEntitlementPublicKeys"], expected)

    def test_checksums_verify_after_artifacts_are_moved(self):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory) / "build"
            download = Path(directory) / "download"
            build.mkdir()
            download.mkdir()
            for extension in ("dmg", "zip", "dSYMs.zip"):
                artifact = build / f"GlassEQ.{extension}"
                artifact.write_bytes(b"artifact")
                script = self.functions("write_checksum") + 'DIST_DIR="$1"; write_checksum "$2"'
                subprocess.run(["bash", "-eu", "-c", script, "test", str(build), str(artifact)], check=True)
            for artifact in build.iterdir():
                artifact.rename(download / artifact.name)
            for checksum in download.glob("*.sha256"):
                self.assertNotIn(directory, checksum.read_text())
                subprocess.run(["shasum", "-a", "256", "-c", checksum.name], cwd=download,
                               check=True, capture_output=True)

    def test_rejected_notarization_reports_the_submission_id_and_cleans_up(self):
        for status in (0, 1):
            with tempfile.TemporaryDirectory() as directory:
                result_path = Path(directory) / "notarization.json"
                script = self.functions("fail", "notarize") + f'''
xcrun() {{ echo '{{"status":"Invalid","id":"submission-id"}}'; return {status}; }}
NOTARY_PROFILE=fixture
TEMP_RESULT="$1"
mktemp() {{ echo "$TEMP_RESULT"; }}
submission="$(notarize artifact.dmg)"
'''
                result = subprocess.run(["/bin/bash", "-eu", "-c", script, "test", str(result_path)],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("submission-id", result.stderr)
                self.assertIn("Invalid", result.stderr)
                self.assertNotIn("unbound variable", result.stderr)
                self.assertFalse(result_path.exists())

    def test_disk_image_detaches_when_verification_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            script = self.functions("fail", "verify_disk_image") + r'''
DMG_MOUNT_DIR="$1/mount"
DMG_PATH="$1/test.dmg"
APP_NAME=GlassEQ
# The mount lacks the app, so validation fails immediately after attachment.
hdiutil() { echo "$1" >> "$LOG"; }
LOG="$1/operations"
verify_disk_image
'''
            result = subprocess.run(["bash", "-eu", "-c", script, "test", directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("detach", (Path(directory) / "operations").read_text())
            self.assertFalse((Path(directory) / "mount").exists())

    def test_disk_image_detaches_on_termination_during_attach(self):
        with tempfile.TemporaryDirectory() as directory:
            script = self.functions("fail", "verify_disk_image") + r'''
DMG_MOUNT_DIR="$1/mount"
DMG_PATH="$1/test.dmg"
APP_NAME=GlassEQ
LOG="$1/operations"
hdiutil() {
    echo "$1" >> "$LOG"
    if [[ "$1" == attach ]]; then
        touch "$READY"
        while true; do sleep 1; done
    fi
}
READY="$1/ready"
verify_disk_image
'''
            process = subprocess.Popen(["bash", "-eu", "-c", script, "test", directory],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not (Path(directory) / "ready").exists():
                    if time.monotonic() >= deadline:
                        self.fail("mock attach did not start")
                    time.sleep(0.01)
                os.killpg(process.pid, signal.SIGTERM)
                _, stderr = process.communicate(timeout=5)
                self.assertIn("detach", (Path(directory) / "operations").read_text(), stderr)
                self.assertFalse((Path(directory) / "mount").exists())
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()


if __name__ == "__main__":
    unittest.main()
