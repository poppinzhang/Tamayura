#!/usr/bin/env python3
"""Create a Windows source handoff without local SDK paths, keys or build files."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import tempfile
import zipfile


ROOT_FILES = (
    "AGENTS.md",
    "CHANGELOG.md",
    "LICENSE",
    "README.md",
    "analysis_options.yaml",
    "l10n.yaml",
    "pubspec.yaml",
    "pubspec.lock",
)
OPTIONAL_FILES = (".gitignore", ".metadata", ".github/workflows/windows.yml")
SOURCE_SUFFIXES = {
    "lib": {".dart", ".arb"},
    "test": {".dart"},
    "tool": {".dart"},
    "proto": {".proto"},
    "assets": {".png", ".jpg", ".jpeg", ".webp", ".ico", ".svg"},
    "docs": {".md"},
    "windows": {".cc", ".cpp", ".h", ".hpp", ".cmake", ".txt", ".manifest", ".rc", ".ico", ".ps1"},
    "scripts": {".ps1", ".py"},
}
EXCLUDED_PARTS = {
    ".git", ".dart_tool", ".gradle", ".vs", ".idea", ".pub-cache",
    ".plugin_symlinks", "ephemeral", "build", "dist", "coverage", "keystore",
    "__pycache__", "node_modules",
}
EXCLUDED_NAMES = {"key.properties", "local.properties", "CMakeCache.txt"}


def source_files(root: Path) -> list[Path]:
    """Use a positive allowlist; never follow links out of the source tree."""
    selected: set[Path] = set()
    for name in ROOT_FILES:
        path = root / name
        if not path.is_file():
            raise ValueError(f"Missing required source file: {name}")
        if path.is_symlink():
            raise ValueError(f"Source symlinks are not allowed: {name}")
        selected.add(path)
    for name in OPTIONAL_FILES:
        path = root / name
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent != root):
            raise ValueError(f"Source symlinks are not allowed: {name}")
        if path.is_file():
            selected.add(path)
    for directory, suffixes in SOURCE_SUFFIXES.items():
        source_root = root / directory
        if source_root.is_symlink():
            raise ValueError(f"Source symlinks are not allowed: {directory}")
        if not source_root.is_dir():
            if directory in {"lib", "test", "windows", "scripts"}:
                raise ValueError(f"Missing required source directory: {directory}")
            continue
        for current, directories, files in os.walk(source_root, followlinks=False):
            parent = Path(current)
            directories[:] = sorted(name for name in directories if name not in EXCLUDED_PARTS)
            for name in directories:
                if (parent / name).is_symlink():
                    raise ValueError(f"Source symlinks are not allowed: {(parent / name).relative_to(root)}")
            for name in files:
                path = parent / name
                if name in EXCLUDED_NAMES or path.suffix.lower() not in suffixes:
                    continue
                if directory == "windows" and path.suffix.lower() == ".txt" and name != "CMakeLists.txt":
                    continue
                if directory == "scripts" and "windows" not in name:
                    continue
                if path.is_symlink():
                    raise ValueError(f"Source symlinks are not allowed: {path.relative_to(root)}")
                selected.add(path)
    return sorted(selected, key=lambda path: path.relative_to(root).as_posix())


def package_source(root: Path) -> tuple[Path, Path]:
    root = root.resolve()
    files = source_files(root)
    match = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", (root / "pubspec.yaml").read_text(encoding="utf-8"), re.MULTILINE)
    if match is None:
        raise ValueError("pubspec.yaml must contain version: major.minor.patch+build")
    version = match[1]
    archive_root = f"Tamayura-{version}-windows-source"
    output = root / "dist" / version
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{archive_root}.zip"
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{archive_root}-", suffix=".zip", dir=output)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
            for path in files:
                entry = zipfile.ZipInfo(f"{archive_root}/{path.relative_to(root).as_posix()}")
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = 0o100644 << 16
                bundle.writestr(entry, path.read_bytes())
        with zipfile.ZipFile(temporary) as bundle:
            corrupted = bundle.testzip()
            if corrupted is not None:
                raise ValueError(f"Archive integrity check failed: {corrupted}")
        temporary.replace(archive)
    finally:
        temporary.unlink(missing_ok=True)
    checksum = output / "SHA256SUMS-windows-source"
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum.write_text(f"{digest}  {archive.name}\n", encoding="ascii")
    return archive, checksum


if __name__ == "__main__":
    archive_path, checksum_path = package_source(Path(__file__).resolve().parent.parent)
    print(f"Windows source archive: {archive_path}")
    print(f"SHA-256: {checksum_path}")
    print("This contains source only. Build and test it on Windows; no Windows binary has been produced.")
