#!/usr/bin/env python3
"""Collect pinned Go dependency license material without local build paths."""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def go(*args):
    return subprocess.check_output(["go", *args], cwd=ROOT / "native", encoding="utf-8")


def main():
    output = pathlib.Path(sys.argv[1])
    # Build scripts pass the exact target environment and entry point. Walking
    # dependencies avoids including upstream's unrelated linters/test tools.
    package = sys.argv[2] if len(sys.argv) > 2 else "./cmd/flutter-tailscale"
    raw = go("list", "-deps", "-json", package)
    decoder = json.JSONDecoder()
    modules = {}
    while raw.strip():
        raw = raw.lstrip()
        item, count = decoder.raw_decode(raw)
        raw = raw[count:]
        module = item.get("Module")
        if module and not module.get("Main"):
            modules[module["Path"]] = module
    sections = ["Flutter-Tailscale native dependency notices\n",
                "This file contains upstream license text for pinned dependencies.\n"]
    go_root = pathlib.Path(go("env", "GOROOT").strip())
    sections.append("\n=== Go runtime ===\n" + (go_root / "LICENSE").read_text(encoding="utf-8"))
    missing = []
    for module in sorted(modules.values(), key=lambda value: value["Path"]):
        directory = module.get("Dir")
        if not directory:
            # go mod download populates platform-only dependency directories.
            details = json.loads(go("mod", "download", "-json", module["Path"] + "@" + module["Version"]))
            directory = details.get("Dir")
        if not directory:
            missing.append(module["Path"])
            continue
        files = sorted(path for path in pathlib.Path(directory).iterdir()
                       if path.is_file() and path.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")))
        if not files:
            missing.append(module["Path"])
            continue
        sections.append("\n=== " + module["Path"] + " " + module.get("Version", "") + " ===\n")
        for path in files:
            sections.append("\n--- " + path.name + " ---\n" + path.read_text(encoding="utf-8", errors="replace") + "\n")
    if missing:
        raise SystemExit("License files missing for: " + ", ".join(missing))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("".join(sections), encoding="utf-8")


if __name__ == "__main__":
    main()
