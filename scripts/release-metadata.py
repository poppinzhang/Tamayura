#!/usr/bin/env python3
"""Validate tag releases and assemble verified assets using only the standard library."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys


NUMBER = r"(?:0|[1-9][0-9]*)"
VERSION = rf"{NUMBER}\.{NUMBER}\.{NUMBER}"
PLATFORMS = {
    "android": {
        "suffix": "android.apk",
        "minimum_os": "Android 16 (API 36)",
        "architectures": ["armeabi-v7a", "arm64-v8a", "x86_64"],
        "signing": {"type": "release-keystore"},
    },
    "macos": {
        "suffix": "macos.zip",
        "minimum_os": "macOS 15.0",
        "architectures": ["arm64", "x86_64"],
        "signing": {"type": "ad-hoc", "notarized": False},
    },
    "windows": {
        "suffix": "windows-x64.zip",
        "minimum_os": "Windows 10 1809 / Windows 11",
        "architectures": ["x64"],
        "signing": {"type": "unsigned"},
    },
}


class ReleaseError(ValueError):
    """An actionable validation error without local environment details."""


def markdown_lines(markdown):
    """Yield (line, heading level, title), ignoring headings inside fenced code."""
    fence_character = None
    fence_length = 0
    for line in markdown.splitlines(keepends=True):
        text = line.rstrip("\r\n")
        if fence_character:
            if re.fullmatch(rf" {{0,3}}{re.escape(fence_character)}{{{fence_length},}}[ \t]*", text):
                fence_character = None
            yield line, None, None
            continue
        fence = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", text)
        if fence and (fence[1][0] != "`" or "`" not in fence[2]):
            fence_character = fence[1][0]
            fence_length = len(fence[1])
            yield line, None, None
            continue
        heading = re.match(r"^ {0,3}(#{1,6})(?:[ \t]+(.*)|[ \t]*)$", text)
        if heading:
            title = re.sub(r"[ \t]+#+[ \t]*$", "", heading[2] or "").strip()
            yield line, len(heading[1]), title
        else:
            yield line, None, None


def has_content(lines):
    # Empty category headings may remain in the release template.
    return any(line.strip() and not (level and level >= 3) for line, level, _ in lines)


def release_information(root, tag):
    if not re.fullmatch(rf"v{VERSION}", tag):
        raise ReleaseError("Tag must have the exact form vMAJOR.MINOR.PATCH (no suffix or leading zero).")
    version = tag[1:]
    pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
    declarations = re.findall(r"^version:(.*)$", pubspec, re.MULTILINE)
    if len(declarations) != 1:
        raise ReleaseError("pubspec.yaml must contain exactly one top-level version declaration.")
    declaration = re.fullmatch(rf" [ \t]*(?P<version>{VERSION})\+(?P<build>[1-9][0-9]*)[ \t]*", declarations[0])
    if not declaration:
        raise ReleaseError("pubspec.yaml version must have the form MAJOR.MINOR.PATCH+BUILD.")
    if declaration["version"] != version:
        raise ReleaseError("Tag version does not match pubspec.yaml.")

    lines = list(markdown_lines((root / "CHANGELOG.md").read_text(encoding="utf-8")))
    sections = []
    for index, (_, level, title) in enumerate(lines):
        if level == 2:
            if sections:
                sections[-1][2] = index
            sections.append([title, index, len(lines)])
    targets = [section for section in sections if section[0] == version]
    if len(targets) != 1:
        raise ReleaseError("CHANGELOG.md must contain exactly one matching version section.")
    versions = [title for title, _, _ in sections if re.fullmatch(VERSION, title)]
    if versions[0] != version or any(tuple(map(int, item.split("."))) > tuple(map(int, version.split("."))) for item in versions):
        raise ReleaseError("The tag must match the latest version section in CHANGELOG.md.")
    unstaged = [section for section in sections if section[0].lower() == "unstaged"]
    if len(unstaged) > 1:
        raise ReleaseError("CHANGELOG.md contains duplicate unstaged sections.")
    if any(has_content(lines[start + 1:end]) for _, start, end in unstaged):
        raise ReleaseError("Move all unreleased changes from unstaged into the version section before tagging.")
    _, start, end = targets[0]
    if not has_content(lines[start + 1:end]):
        raise ReleaseError("The matching changelog version section is empty.")
    notes = "".join(line for line, _, _ in lines[start:end]).rstrip() + "\n"
    return version, int(declaration["build"]), notes


def empty_output_directory(output_dir):
    if output_dir.is_symlink() or (output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir()))):
        raise ReleaseError("The output directory must be empty and must not be a symlink.")
    output_dir.mkdir(parents=True, exist_ok=True)


def prepare(root, tag, output_dir):
    version, build_number, notes = release_information(root, tag)
    empty_output_directory(output_dir)
    (output_dir / "release-notes.md").write_text(notes, encoding="utf-8", newline="\n")
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8", newline="\n") as output:
            output.write(f"version={version}\nbuild_number={build_number}\n")
    print(f"Prepared {tag} (build {build_number}): release-notes.md")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def assemble(root, tag, artifacts_dir, output_dir):
    version, build_number, _ = release_information(root, tag)
    filenames = {platform: f"Tamayura-{version}-{details['suffix']}" for platform, details in PLATFORMS.items()}
    expected = set(filenames.values()) | {f"SHA256SUMS-{platform}" for platform in PLATFORMS}
    if artifacts_dir.is_symlink() or not artifacts_dir.is_dir():
        raise ReleaseError("The artifacts directory must be a real directory.")
    entries = list(artifacts_dir.iterdir())
    if {entry.name for entry in entries} != expected:
        raise ReleaseError("Artifacts must contain exactly the three platform packages and their three SHA256SUMS files.")
    if any(entry.is_symlink() or not entry.is_file() or entry.stat().st_size == 0 for entry in entries):
        raise ReleaseError("Artifacts must be nonempty regular files; directories and symlinks are rejected.")

    platforms = {}
    checksums = []
    for platform, filename in filenames.items():
        checksum = (artifacts_dir / f"SHA256SUMS-{platform}").read_text(encoding="ascii").splitlines()
        match = re.fullmatch(rf"([0-9a-fA-F]{{64}}) [ *]{re.escape(filename)}", checksum[0]) if len(checksum) == 1 else None
        if not match:
            raise ReleaseError(f"SHA256SUMS-{platform} must contain one checksum for its expected package.")
        package = artifacts_dir / filename
        digest = sha256(package)
        if digest != match[1].lower():
            raise ReleaseError(f"Checksum mismatch for {filename}.")
        platforms[platform] = {
            "filename": filename,
            "size_bytes": package.stat().st_size,
            "sha256": digest,
            **{key: value for key, value in PLATFORMS[platform].items() if key != "suffix"},
        }
        checksums.append(f"{digest}  {filename}\n")

    empty_output_directory(output_dir)
    for filename in filenames.values():
        shutil.copyfile(artifacts_dir / filename, output_dir / filename)
    (output_dir / "SHA256SUMS").write_text("".join(checksums), encoding="ascii", newline="\n")
    metadata = {
        "tag": tag,
        "version": version,
        "build_number": build_number,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "release_type": "prerelease",
        "validation": {
            "automated_builds_and_checks": "completed",
            "physical_device_acceptance": "not_confirmed",
        },
        "platforms": platforms,
    }
    (output_dir / "release.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"Assembled {tag} (build {build_number}): three packages, SHA256SUMS, release.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "assemble"):
        command = subcommands.add_parser(name)
        command.add_argument("--tag", required=True)
        command.add_argument("--output-dir", required=True, type=Path)
        if name == "assemble":
            command.add_argument("--artifacts-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(Path.cwd(), args.tag, args.output_dir)
        else:
            assemble(Path.cwd(), args.tag, args.artifacts_dir, args.output_dir)
    except ReleaseError as error:
        print(f"Release validation failed: {error}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError):
        # OS exceptions can contain credentials or private absolute build paths.
        print("Release validation failed: unable to read or write release files; check their presence, encoding and permissions.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
