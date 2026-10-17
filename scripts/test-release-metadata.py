#!/usr/bin/env python3
"""Host-independent regression tests for the tag release command-line contract."""

import hashlib
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("release-metadata.py").resolve()
VERSION = "0.6.0"
TAG = "v0.6.0"
NOTES = "## 0.6.0\n\n发布日期：2026-10-17。\n\n### 已完成功能\n\n- 新的局域网功能。\n"
CHANGELOG = "# 更新记录\n\n## unstaged\n\n### 已完成功能\n\n### 修复\n\n" + NOTES + "\n## 0.5.0\n\n- 历史内容。\n"
PACKAGES = {
    "android": "Tamayura-0.6.0-android.apk",
    "macos": "Tamayura-0.6.0-macos.zip",
    "windows": "Tamayura-0.6.0-windows-x64.zip",
}


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.write("pubspec.yaml", "name: tamayura\nversion: 0.6.0+9\n")
        self.write("CHANGELOG.md", CHANGELOG)

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode("utf-8"))
        return path

    def run_command(self, command="prepare", tag=TAG, output="output", github_output=False):
        arguments = [sys.executable, str(SCRIPT), command, "--tag", tag, "--output-dir", str(self.root / output)]
        if command == "assemble":
            arguments.extend(["--artifacts-dir", str(self.root / "artifacts")])
        environment = os.environ.copy()
        environment.pop("GITHUB_OUTPUT", None)
        if github_output:
            environment["GITHUB_OUTPUT"] = str(self.root / "github-output")
        result = subprocess.run(arguments, cwd=self.root, env=environment, capture_output=True, text=True)
        self.assertNotIn(str(self.root), result.stdout + result.stderr)
        return result

    def assert_failure(self, result, expected):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stderr)
        self.assertFalse((self.root / "output").exists())

    def create_artifacts(self):
        for platform, filename in PACKAGES.items():
            package = self.write(f"artifacts/{filename}", f"built package: {platform}\n")
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            self.write(f"artifacts/SHA256SUMS-{platform}", f"{digest}  {filename}\n")

    def test_prepare_preserves_complete_version_notes_and_appends_github_outputs(self):
        self.write("github-output", "existing=value\n")
        result = self.run_command(github_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "output/release-notes.md").read_text(encoding="utf-8"), NOTES)
        self.assertEqual((self.root / "github-output").read_text(), "existing=value\nversion=0.6.0\nbuild_number=9\n")
        self.assertNotIn("历史内容", (self.root / "output/release-notes.md").read_text(encoding="utf-8"))

    def test_crlf_and_trailing_pubspec_whitespace_are_supported(self):
        self.write("pubspec.yaml", "name: tamayura\r\nversion: 0.6.0+9 \t\r\n")
        self.write("CHANGELOG.md", CHANGELOG.replace("\n", "\r\n"))
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "output/release-notes.md").read_bytes(), NOTES.encode("utf-8"))

    def test_fenced_fake_headings_do_not_split_or_duplicate_release_sections(self):
        notes = NOTES + '\n```markdown\n## 0.6.0\n## unstaged\n```\n\n~~~markdown\n## 99.0.0\n~~~\n'
        self.write("CHANGELOG.md", "# 更新记录\n\n" + notes + "\n## 0.5.0\n\n- Old.\n")
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "output/release-notes.md").read_text(encoding="utf-8"), notes)

    def test_strict_tag_format(self):
        for tag in ("0.6.0", "v0.6", "v00.6.0", "v0.6.0-rc.1", "v0.6.0+9", "v0.6.0\n", "v0.6.0/extra"):
            with self.subTest(tag=tag):
                self.assert_failure(self.run_command(tag=tag), "exact form")

    def test_tag_pubspec_mismatch(self):
        self.assert_failure(self.run_command(tag="v0.7.0"), "does not match pubspec")

    def test_invalid_or_duplicate_pubspec_version_is_rejected(self):
        for declaration in ("version: 0.6.0\n", "version: 0.6.0+0\n", "version:0.6.0+9\n", "version:\t0.6.0+9\n", "version: 0.6.0+9\nversion: 0.6.0+9\n", "name: tamayura\n", "version: '0.6.0+9\"\n"):
            with self.subTest(declaration=declaration):
                self.write("pubspec.yaml", declaration)
                self.assert_failure(self.run_command(), "pubspec.yaml")

    def test_quoted_pubspec_versions_and_inline_comments_are_rejected(self):
        for declaration in ('version: "0.6.0+9"\n', "version: '0.6.0+9'\n", "version: 0.6.0+9 # release\n"):
            with self.subTest(declaration=declaration):
                self.write("pubspec.yaml", declaration)
                self.assert_failure(self.run_command(), "pubspec.yaml version must have the form")

    def test_missing_duplicate_or_empty_target_section_is_rejected(self):
        cases = {
            "missing": ("## 0.5.0\n\n- Old.\n", "exactly one"),
            "duplicate": (CHANGELOG + "\n" + NOTES, "exactly one"),
            "empty": ("## 0.6.0\n\n### 修复\n\n### 已知限制\n", "is empty"),
        }
        for name, (content, message) in cases.items():
            with self.subTest(name=name):
                self.write("CHANGELOG.md", content)
                self.assert_failure(self.run_command(), message)

    def test_unreleased_changes_prevent_publishing_existing_version(self):
        for content in ("- 尚未发布的功能。", "未发布说明", "```md\n### 不是分类\n```", "<!-- 待发布 -->"):
            with self.subTest(content=content):
                self.write("CHANGELOG.md", "## unstaged\n\n### 已完成功能\n\n" + content + "\n\n" + NOTES)
                self.assert_failure(self.run_command(), "unreleased changes")

    def test_target_must_be_first_and_highest_version(self):
        for changelog in ("## 0.7.0\n\n- Newer.\n\n" + NOTES, NOTES + "\n## 0.7.0\n\n- Newer.\n", "## 0.5.0\n\n- Old.\n\n" + NOTES):
            with self.subTest(changelog=changelog):
                self.write("CHANGELOG.md", changelog)
                self.assert_failure(self.run_command(), "latest version")

    def test_duplicate_unstaged_sections_are_rejected(self):
        self.write("CHANGELOG.md", "## unstaged\n\n" + CHANGELOG)
        self.assert_failure(self.run_command(), "duplicate unstaged")

    def test_assemble_verifies_and_describes_all_three_packages(self):
        self.create_artifacts()
        result = self.run_command("assemble")
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.root / "output"
        self.assertEqual({entry.name for entry in output.iterdir()}, set(PACKAGES.values()) | {"SHA256SUMS", "release.json"})
        metadata = json.loads((output / "release.json").read_text())
        self.assertEqual((metadata["tag"], metadata["version"], metadata["build_number"]), (TAG, VERSION, 9))
        self.assertEqual(datetime.fromisoformat(metadata["generated_at"]).utcoffset(), timedelta(0))
        self.assertEqual(metadata["release_type"], "prerelease")
        self.assertEqual(metadata["validation"]["physical_device_acceptance"], "not_confirmed")
        self.assertEqual(metadata["platforms"]["macos"]["signing"], {"type": "ad-hoc", "notarized": False})
        self.assertEqual(metadata["platforms"]["windows"]["signing"], {"type": "unsigned"})
        checksum_lines = (output / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(checksum_lines), 3)
        for platform, filename in PACKAGES.items():
            original = (self.root / "artifacts" / filename).read_bytes()
            self.assertEqual((output / filename).read_bytes(), original)
            info = metadata["platforms"][platform]
            self.assertEqual(info["size_bytes"], len(original))
            self.assertEqual(info["sha256"], hashlib.sha256(original).hexdigest())
            self.assertIn(f"{info['sha256']}  {filename}", checksum_lines)
            self.assertTrue(info["minimum_os"])
            self.assertTrue(info["architectures"])
        self.assertNotIn(str(self.root), (output / "release.json").read_text())

    def test_missing_package_or_checksum_is_rejected(self):
        self.create_artifacts()
        for filename in (*PACKAGES.values(), "SHA256SUMS-android", "SHA256SUMS-macos", "SHA256SUMS-windows"):
            with self.subTest(filename=filename):
                path = self.root / "artifacts" / filename
                content = path.read_bytes()
                path.unlink()
                self.assert_failure(self.run_command("assemble"), "exactly the three")
                path.write_bytes(content)

    def test_windows_checksum_line_endings_and_uppercase_digest_are_supported(self):
        self.create_artifacts()
        checksum = self.root / "artifacts/SHA256SUMS-windows"
        digest, filename = checksum.read_text().strip().split("  ")
        checksum.write_bytes(f"{digest.upper()}  {filename}\r\n".encode("ascii"))
        result = self.run_command("assemble")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_empty_files_are_rejected(self):
        self.create_artifacts()
        for filename in (PACKAGES["android"], "SHA256SUMS-windows"):
            with self.subTest(filename=filename):
                path = self.root / "artifacts" / filename
                content = path.read_bytes()
                path.write_bytes(b"")
                self.assert_failure(self.run_command("assemble"), "nonempty regular")
                path.write_bytes(content)

    def test_tampered_package_is_rejected(self):
        self.create_artifacts()
        self.write(f"artifacts/{PACKAGES['macos']}", "tampered")
        self.assert_failure(self.run_command("assemble"), "Checksum mismatch")

    def test_checksum_cannot_reference_other_files_or_multiple_files(self):
        self.create_artifacts()
        filename = PACKAGES["android"]
        checksum_path = self.root / "artifacts/SHA256SUMS-android"
        valid = checksum_path.read_text()
        for content in (valid.replace(filename, "../" + filename), valid + valid, valid.replace(filename, PACKAGES["macos"]), "not-a-sha256  " + filename + "\n"):
            with self.subTest(content=content):
                checksum_path.write_text(content)
                self.assert_failure(self.run_command("assemble"), "one checksum")

    def test_extra_file_and_directory_are_rejected(self):
        self.create_artifacts()
        for filename in ("debug.apk", ".secret"):
            extra = self.write(f"artifacts/{filename}", "extra")
            self.assert_failure(self.run_command("assemble"), "exactly the three")
            extra.unlink()
        package = self.root / "artifacts" / PACKAGES["android"]
        package.unlink()
        package.mkdir()
        self.assert_failure(self.run_command("assemble"), "nonempty regular")

    def test_symlinked_package_is_rejected(self):
        self.create_artifacts()
        package = self.root / "artifacts" / PACKAGES["android"]
        target = self.root / "original.apk"
        package.rename(target)
        try:
            package.symlink_to(target)
        except OSError:
            self.skipTest("Creating symlinks is not permitted on this host")
        self.assert_failure(self.run_command("assemble"), "symlinks are rejected")

    def test_symlinked_artifact_directory_is_rejected(self):
        self.create_artifacts()
        artifacts = self.root / "artifacts"
        original = self.root / "original-artifacts"
        artifacts.rename(original)
        try:
            artifacts.symlink_to(original, target_is_directory=True)
        except OSError:
            self.skipTest("Creating symlinks is not permitted on this host")
        self.assert_failure(self.run_command("assemble"), "real directory")

    def test_symlinked_output_directory_is_rejected(self):
        original = self.root / "original-output"
        original.mkdir()
        try:
            (self.root / "output").symlink_to(original, target_is_directory=True)
        except OSError:
            self.skipTest("Creating symlinks is not permitted on this host")
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not be a symlink", result.stderr)
        self.assertEqual(list(original.iterdir()), [])

    def test_output_does_not_overwrite_existing_files(self):
        self.write("output/keep.txt", "existing file")
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be empty", result.stderr)
        self.assertEqual((self.root / "output/keep.txt").read_text(), "existing file")
        self.assertFalse((self.root / "output/release-notes.md").exists())

    def test_input_io_error_does_not_print_private_paths(self):
        (self.root / "pubspec.yaml").unlink()
        self.assert_failure(self.run_command(), "unable to read or write release files")


if __name__ == "__main__":
    unittest.main()
