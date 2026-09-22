import base64
import json
import os
from pathlib import Path
import plistlib
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
            self.assertIn("Licensing: embedded from", result.stdout)
            for omitted in required:
                with self.subTest(omitted=omitted):
                    result = self.dry_run("RELEASE_CHANNEL=production", *(item for item in required if item != omitted))
                    self.assertNotEqual(result.returncode, 0)

    def test_entitlement_public_keys_file_is_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            for content in ("not json", "{}", json.dumps({"k1": "short"}), json.dumps({"k1": 5})):
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
            self.assertIn("Licensing: embedded from", result.stdout)

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


if __name__ == "__main__":
    unittest.main()
