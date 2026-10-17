#!/usr/bin/env python3
"""Regression checks for the Windows handoff allowlist, independent of the host."""

import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("package_windows_source", Path(__file__).with_name("package-windows-source.py"))
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class WindowsSourceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        for filename in PACKAGE.ROOT_FILES:
            self.write(filename, "version: 0.3.0+6\n" if filename == "pubspec.yaml" else "source\n")
        for filename in ("lib/main.dart", "test/app_test.dart", "windows/CMakeLists.txt", "windows/runner/main.cpp", "scripts/package-windows.ps1", "docs/Windows原型.md"):
            self.write(filename, "source\n")

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def test_source_archive_excludes_secrets_generated_files_and_other_platforms(self):
        for name in ("android/key.properties", "android/keystore/release.jks", "android/local.properties", "macos/Runner/main.swift", ".env", ".git/config", "dist/old.zip", "build/old.dll", "windows/flutter/ephemeral/secret.h", "windows/build/secret.cpp", "windows/CMakeCache.txt", "windows/debug-log.txt", "windows/runner/secret.pfx", "scripts/__pycache__/package-windows.py", "scripts/unrelated.py", "docs/private.txt"):
            self.write(name, "LOCAL_ONLY\n")
        self.write("windows/flutter/generated_plugin_registrant.cc", "source\n")
        self.write(".github/workflows/windows.yml", "source\n")
        archive, checksum = PACKAGE.package_source(self.root)
        with zipfile.ZipFile(archive) as bundle:
            names = {name.split("/", 1)[1] for name in bundle.namelist()}
            self.assertIn("windows/runner/main.cpp", names)
            self.assertIn("windows/flutter/generated_plugin_registrant.cc", names)
            self.assertIn(".github/workflows/windows.yml", names)
            for name in bundle.namelist():
                self.assertNotIn(b"LOCAL_ONLY", bundle.read(name))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.assertEqual(checksum.read_text(), f"{digest}  {archive.name}\n")

    def test_repeated_packaging_does_not_include_previous_output(self):
        archive, _ = PACKAGE.package_source(self.root)
        original = archive.read_bytes()
        PACKAGE.package_source(self.root)
        self.assertEqual(original, archive.read_bytes())

    def test_update_helpers_and_regression_scripts_are_included(self):
        required = ("windows/runner/tamayura-update.ps1", "windows/runner/windows_update.cpp", "windows/runner/windows_update.h", "windows/tests/update_test.ps1")
        for name in required:
            self.write(name, "source\n")
        archive, _ = PACKAGE.package_source(self.root)
        with zipfile.ZipFile(archive) as bundle:
            names = {name.split("/", 1)[1] for name in bundle.namelist()}
            self.assertTrue(set(required).issubset(names))

    def test_symlink_is_rejected(self):
        target = self.write("private.dart", "LOCAL_ONLY\n")
        try:
            (self.root / "lib/linked.dart").symlink_to(target)
        except OSError:
            self.skipTest("Creating symlinks is not permitted on this host")
        with self.assertRaisesRegex(ValueError, "symlinks"):
            PACKAGE.package_source(self.root)

    def test_missing_required_files_fail_before_creating_output(self):
        (self.root / "pubspec.lock").unlink()
        with self.assertRaisesRegex(ValueError, "Missing required source file"):
            PACKAGE.package_source(self.root)
        self.assertFalse((self.root / "dist").exists())


if __name__ == "__main__":
    unittest.main()
