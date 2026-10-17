#!/usr/bin/env python3
"""Regression tests for Android signing and packaging without an Android SDK."""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("configure_android_signing", SCRIPTS / "configure-android-signing.py")
SIGNING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNING)
SECRETS = {
    "ANDROID_KEYSTORE_BASE64": base64.b64encode(b"fake-keystore-for-tests-only").decode(),
    "ANDROID_KEYSTORE_PASSWORD": " password:=#!\\\t\n\r\f测试🎵 ",
    "ANDROID_KEY_ALIAS": " key:=#!\\测试 ",
    "ANDROID_KEY_PASSWORD": " different-test-password ",
}


class SigningTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "android").mkdir()

    def test_secret_values_are_java_properties_escaped_and_private(self):
        SIGNING.configure(self.root, SECRETS)
        properties = (self.root / SIGNING.PROPERTIES).read_text(encoding="ascii")
        self.assertEqual((self.root / SIGNING.KEYSTORE).read_bytes(), b"fake-keystore-for-tests-only")
        self.assertIn("storeFile=../keystore/ci-release.jks\n", properties)
        self.assertIn(r"storePassword=\ password\:\=\#\!\\\t\n\r\f\u6d4b\u8bd5\ud83c\udfb5\ ", properties)
        self.assertIn(r"keyAlias=\ key\:\=\#\!\\\u6d4b\u8bd5\ ", properties)
        self.assertEqual(len(properties.splitlines()), 4)
        for relative in (SIGNING.PROPERTIES, SIGNING.KEYSTORE, SIGNING.STATE):
            self.assertEqual(stat.S_IMODE((self.root / relative).stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.root / SIGNING.KEYSTORE.parent).stat().st_mode), 0o700)

    def test_cleanup_is_idempotent_and_preserves_other_local_files(self):
        SIGNING.configure(self.root, SECRETS)
        local = self.root / "android/keystore/local.jks"
        local.write_bytes(b"local-test-keystore")
        SIGNING.cleanup(self.root)
        SIGNING.cleanup(self.root)
        self.assertEqual(local.read_bytes(), b"local-test-keystore")
        self.assertFalse((self.root / SIGNING.PROPERTIES).exists())
        self.assertFalse((self.root / SIGNING.KEYSTORE).exists())
        self.assertFalse((self.root / SIGNING.STATE).exists())

    def test_line_wrapped_base64_and_trailing_newline_are_accepted(self):
        encoded = SECRETS["ANDROID_KEYSTORE_BASE64"]
        wrapped = " \t\r\n" + "\n".join(encoded[index:index + 8] for index in range(0, len(encoded), 8)) + "\n"
        SIGNING.configure(self.root, dict(SECRETS, ANDROID_KEYSTORE_BASE64=wrapped))
        self.assertEqual((self.root / SIGNING.KEYSTORE).read_bytes(), b"fake-keystore-for-tests-only")

    def test_cleanup_removes_its_empty_directory(self):
        SIGNING.configure(self.root, SECRETS)
        SIGNING.cleanup(self.root)
        self.assertFalse((self.root / SIGNING.KEYSTORE.parent).exists())

    def test_cleanup_without_marker_does_not_remove_local_signing(self):
        local = self.root / SIGNING.PROPERTIES
        local.write_text("local-test-signing")
        SIGNING.cleanup(self.root)
        self.assertEqual(local.read_text(), "local-test-signing")

    def test_cleanup_refuses_changed_files_before_deleting_anything(self):
        SIGNING.configure(self.root, SECRETS)
        (self.root / SIGNING.PROPERTIES).write_text("updated-local-test-signing")
        with self.assertRaisesRegex(ValueError, "changed"):
            SIGNING.cleanup(self.root)
        self.assertTrue((self.root / SIGNING.KEYSTORE).exists())
        self.assertTrue((self.root / SIGNING.STATE).exists())

    def test_cleanup_refuses_symlinked_signing_file(self):
        SIGNING.configure(self.root, SECRETS)
        target = self.root / "other.properties"
        target.write_text("local-test-signing")
        (self.root / SIGNING.PROPERTIES).unlink()
        (self.root / SIGNING.PROPERTIES).symlink_to(target)
        with self.assertRaisesRegex(ValueError, "changed"):
            SIGNING.cleanup(self.root)
        self.assertEqual(target.read_text(), "local-test-signing")

    def test_missing_or_invalid_secrets_fail_without_writing(self):
        variants = [dict(SECRETS, **{name: ""}) for name in SIGNING.ENV_NAMES]
        variants.append(dict(SECRETS, ANDROID_KEYSTORE_BASE64="invalid-base64"))
        variants.append(dict(SECRETS, ANDROID_KEYSTORE_BASE64=" \t\r\n"))
        for environment in variants:
            with self.subTest(secret_input=list(environment.values())[0]):
                with self.assertRaises(ValueError):
                    SIGNING.configure(self.root, environment)
                self.assertEqual(list((self.root / "android").iterdir()), [])

    def test_existing_signing_is_not_overwritten(self):
        local = self.root / SIGNING.PROPERTIES
        local.write_text("local-test-signing")
        with self.assertRaisesRegex(ValueError, "not be overwritten"):
            SIGNING.configure(self.root, SECRETS)
        self.assertEqual(local.read_text(), "local-test-signing")

    def test_existing_keystore_is_not_overwritten(self):
        local = self.root / SIGNING.KEYSTORE
        local.parent.mkdir(mode=0o700)
        local.write_bytes(b"local-test-keystore")
        with self.assertRaisesRegex(ValueError, "not be overwritten"):
            SIGNING.configure(self.root, SECRETS)
        self.assertEqual(local.read_bytes(), b"local-test-keystore")
        self.assertFalse((self.root / SIGNING.PROPERTIES).exists())

    def test_public_existing_keystore_directory_is_not_changed(self):
        directory = self.root / SIGNING.KEYSTORE.parent
        directory.mkdir(mode=0o755)
        with self.assertRaisesRegex(ValueError, "private"):
            SIGNING.configure(self.root, SECRETS)
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o755)
        self.assertEqual(list(directory.iterdir()), [])

    def test_symlinked_keystore_directory_is_rejected(self):
        other = self.root / "other-keystores"
        other.mkdir()
        (self.root / SIGNING.KEYSTORE.parent).symlink_to(other)
        with self.assertRaisesRegex(ValueError, "symbolic"):
            SIGNING.configure(self.root, SECRETS)
        self.assertEqual(list(other.iterdir()), [])

    def test_invalid_cleanup_marker_cannot_choose_arbitrary_files(self):
        SIGNING.configure(self.root, SECRETS)
        local = self.root / "local.txt"
        local.write_text("local")
        (self.root / SIGNING.STATE).write_text(json.dumps({"schema": 1, "sha256": {"local.txt": hashlib.sha256(b"local").hexdigest()}}))
        with self.assertRaisesRegex(ValueError, "marker is invalid"):
            SIGNING.cleanup(self.root)
        self.assertEqual(local.read_text(), "local")

    def test_write_failure_rolls_back_created_files(self):
        from unittest import mock

        original_write = SIGNING.write_private

        def fail_properties(path, content):
            if path == self.root / SIGNING.PROPERTIES:
                raise OSError("test disk failure")
            original_write(path, content)

        with mock.patch.object(SIGNING, "write_private", side_effect=fail_properties):
            with self.assertRaises(OSError):
                SIGNING.configure(self.root, SECRETS)
        self.assertEqual(list((self.root / "android").iterdir()), [])

    def test_cli_does_not_print_secrets_or_host_paths(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy(SCRIPTS / "configure-android-signing.py", scripts)
        environment = dict(os.environ, **SECRETS)
        for arguments in ([], ["cleanup"]):
            result = subprocess.run([sys.executable, str(scripts / "configure-android-signing.py"), *arguments], env=environment, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for forbidden in (*SECRETS.values(), str(self.root)):
                self.assertNotIn(forbidden, result.stdout + result.stderr)


MOCK_TOOL_SOURCE = r'''
import json
import os
from pathlib import Path
import sys
import zipfile

tool = Path(sys.argv[0]).name
command = " ".join([tool, *sys.argv[1:]])
with Path(os.environ["MOCK_LOG"]).open("a") as log:
    log.write(json.dumps([tool, *sys.argv[1:]]) + "\n")
if command.startswith(os.environ.get("FAIL_COMMAND", "NEVER_FAIL")):
    sys.exit(23)
if tool == "flutter" and sys.argv[1:3] == ["--version", "--machine"]:
    if os.environ.get("MOCK_INVALID_SDK_JSON"):
        print("invalid SDK JSON")
    else:
        print(json.dumps({"flutterVersion": os.environ.get("MOCK_FLUTTER_VERSION", "3.47.6"), "dartSdkVersion": os.environ.get("MOCK_DART_VERSION", "3.13.5")}))
if tool == "flutter" and sys.argv[1:3] == ["build", "apk"] and not os.environ.get("MOCK_MISSING_APK"):
    apk = Path("build/app/outputs/flutter-apk/app-release.apk")
    apk.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(apk, "w") as archive:
        for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
            for library in ("libapp.so", "libflutter.so"):
                if os.environ.get("MOCK_MISSING_ABI") != abi:
                    archive.writestr(f"lib/{abi}/{library}", "fake native test fixture")
if tool == "aapt":
    print("package: name='%s' versionCode='%s' versionName='%s'" % (os.environ.get("MOCK_APP_ID", "dev.tamayura.app"), os.environ.get("MOCK_BUILD", "17"), os.environ.get("MOCK_VERSION", "0.6.0")))
    print("sdkVersion:'%s'" % os.environ.get("MOCK_MIN_SDK", "36"))
    print("targetSdkVersion:'%s'" % os.environ.get("MOCK_TARGET_SDK", "36"))
    print("native-code: " + os.environ.get("MOCK_ABIS", "'armeabi-v7a' 'arm64-v8a' 'x86_64'"))
    if os.environ.get("MOCK_DEBUGGABLE"):
        print("application-debuggable")
if tool == "apksigner":
    print("Signer #1 certificate DN: CN=%s, O=Test" % ("Android Debug" if os.environ.get("MOCK_DEBUG_SIGNATURE") else "Release Test Fixture"))
'''


class AndroidPackagingTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "scripts").mkdir()
        shutil.copy(SCRIPTS / "package-android.sh", self.root / "scripts")
        (self.root / "pubspec.yaml").write_text("version: 0.6.0+17\n")
        (self.root / "android").mkdir()
        (self.root / "android/key.properties").write_text("test fixture only\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.sdk_tools = self.root / "sdk/build-tools/36.0.0"
        self.sdk_tools.mkdir(parents=True)
        for path in [self.bin / "flutter", self.bin / "dart", self.root / "android/gradlew", *(self.sdk_tools / name for name in ("aapt", "apksigner", "zipalign"))]:
            path.write_text(f"#!{sys.executable}\n{MOCK_TOOL_SOURCE}")
            path.chmod(0o755)
        self.log = self.root / "calls.jsonl"
        self.environment = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", ANDROID_SDK_ROOT=str(self.root / "sdk"), MOCK_LOG=str(self.log))
        self.output = self.root / "dist/0.6.0/Tamayura-0.6.0-android.apk"

    def run_package(self, **overrides):
        return subprocess.run(["bash", str(self.root / "scripts/package-android.sh")], env=dict(self.environment, **overrides), capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_full_checks_and_signed_apk_are_packaged_with_checksum(self):
        output_dir = self.output.parent
        output_dir.mkdir(parents=True)
        other_checksum = output_dir / "SHA256SUMS-macos"
        other_checksum.write_text("unrelated checksum")
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls()[:7], [
            ["flutter", "--version", "--machine"],
            ["flutter", "pub", "get", "--enforce-lockfile"],
            ["dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test"],
            ["flutter", "analyze", "--no-pub"],
            ["flutter", "test", "--no-pub", "--coverage"],
            ["gradlew", "testDebugUnitTest"],
            ["flutter", "build", "apk", "--release", "--no-pub"],
        ])
        self.assertIn(["zipalign", "-c", "-P", "16", "-v", "4", "build/app/outputs/flutter-apk/app-release.apk"], self.calls())
        checksum = hashlib.sha256(self.output.read_bytes()).hexdigest()
        self.assertEqual((output_dir / "SHA256SUMS-android").read_text(), f"{checksum}  {self.output.name}\n")
        self.assertEqual(other_checksum.read_text(), "unrelated checksum")
        self.assertNotIn(str(self.root), result.stdout + result.stderr)

    def test_missing_signing_fails_before_flutter(self):
        (self.root / "android/key.properties").unlink()
        result = self.run_package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("debug signing is not allowed", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_missing_sdk_tool_fails_before_flutter(self):
        (self.sdk_tools / "apksigner").unlink()
        result = self.run_package()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_invalid_pubspec_version_fails_before_flutter(self):
        (self.root / "pubspec.yaml").write_text("version: 0.6.0\n")
        result = self.run_package()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_test_or_build_failures_stop_before_packaging(self):
        for command in ("flutter pub get", "dart format", "flutter analyze", "flutter test", "gradlew", "flutter build apk"):
            with self.subTest(command=command):
                self.log.unlink(missing_ok=True)
                result = self.run_package(FAIL_COMMAND=command)
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertTrue(" ".join(self.calls()[-1]).startswith(command))
                self.assertFalse(self.output.exists())

    def test_wrong_sdk_or_missing_apk_is_rejected(self):
        for overrides in ({"MOCK_FLUTTER_VERSION": "3.0.0"}, {"MOCK_DART_VERSION": ""}, {"MOCK_INVALID_SDK_JSON": "1"}, {"MOCK_MISSING_APK": "1"}):
            with self.subTest(overrides=overrides):
                result = self.run_package(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())
                self.assertNotIn("Traceback", result.stderr)

    def test_manifest_abis_and_signing_errors_prevent_distribution(self):
        invalid_metadata = (
            {"MOCK_APP_ID": "other.app"},
            {"MOCK_VERSION": "0.5.0"},
            {"MOCK_BUILD": "16"},
            {"MOCK_MIN_SDK": "35"},
            {"MOCK_TARGET_SDK": "35"},
            {"MOCK_DEBUGGABLE": "1"},
            {"MOCK_ABIS": "'arm64-v8a'"},
            {"MOCK_MISSING_ABI": "x86_64"},
            {"MOCK_DEBUG_SIGNATURE": "1"},
            {"FAIL_COMMAND": "aapt"},
            {"FAIL_COMMAND": "apksigner"},
            {"FAIL_COMMAND": "zipalign"},
        )
        for overrides in invalid_metadata:
            with self.subTest(overrides=overrides):
                result = self.run_package(**overrides)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.output.exists())
                self.assertNotIn(str(self.root), result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
