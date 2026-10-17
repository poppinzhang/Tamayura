#!/usr/bin/env python3
"""Create private, temporary Android signing files from CI secrets."""

import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
KEYSTORE = Path("android/keystore/ci-release.jks")
PROPERTIES = Path("android/key.properties")
STATE = Path("android/keystore/.ci-release-signing.json")
ENV_NAMES = (
    "ANDROID_KEYSTORE_BASE64",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
)


def property_value(value):
    """Encode Java Properties.load(InputStream) values without losing characters."""
    result = []
    escapes = {"\\": "\\\\", "\t": "\\t", "\n": "\\n", "\r": "\\r", "\f": "\\f"}
    for character in value:
        if character in escapes:
            result.append(escapes[character])
        elif character in " =:#!":
            result.append("\\" + character)
        elif ord(character) < 0x20 or ord(character) > 0x7e:
            units = character.encode("utf-16-be")
            result.extend(f"\\u{int.from_bytes(units[index:index + 2], 'big'):04x}" for index in range(0, len(units), 2))
        else:
            result.append(character)
    return "".join(result)


def write_private(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
    except OSError:
        path.unlink(missing_ok=True)
        raise


def configure(root, environment):
    if any(not environment.get(name) for name in ENV_NAMES):
        raise ValueError("All four ANDROID signing secrets must be configured and nonempty.")
    try:
        encoded = environment[ENV_NAMES[0]].translate(str.maketrans("", "", " \t\r\n\v\f"))
        keystore = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("ANDROID_KEYSTORE_BASE64 must contain valid Base64.") from None
    if not keystore:
        raise ValueError("The decoded Android keystore is empty.")
    properties = "\n".join((
        "storeFile=../keystore/ci-release.jks",
        f"storePassword={property_value(environment['ANDROID_KEYSTORE_PASSWORD'])}",
        f"keyAlias={property_value(environment['ANDROID_KEY_ALIAS'])}",
        f"keyPassword={property_value(environment['ANDROID_KEY_PASSWORD'])}",
        "",
    )).encode("ascii")
    targets = {KEYSTORE: keystore, PROPERTIES: properties}
    for path in (*targets, STATE):
        if (root / path).exists() or (root / path).is_symlink():
            raise ValueError("Existing Android signing files will not be overwritten; use a clean CI checkout.")
    directory = root / KEYSTORE.parent
    if directory.is_symlink() or (root / "android").is_symlink():
        raise ValueError("Android signing directories must not be symbolic links.")
    created_directory = not directory.exists()
    if created_directory:
        directory.mkdir(mode=0o700)
    elif not directory.is_dir() or directory.stat().st_mode & 0o077:
        raise ValueError("An existing Android keystore directory must be private (0700).")
    state = {
        "schema": 1,
        "created_directory": created_directory,
        "sha256": {str(path): hashlib.sha256(content).hexdigest() for path, content in targets.items()},
    }
    created = []
    try:
        write_private(root / STATE, json.dumps(state).encode("ascii"))
        created.append(root / STATE)
        for path, content in targets.items():
            write_private(root / path, content)
            created.append(root / path)
    except OSError:
        for path in reversed(created):
            path.unlink(missing_ok=True)
        if created_directory:
            directory.rmdir()
        raise


def cleanup(root):
    marker = root / STATE
    if not marker.exists() and not marker.is_symlink():
        return
    if marker.is_symlink() or (root / KEYSTORE.parent).is_symlink() or (root / "android").is_symlink():
        raise ValueError("Refusing to clean symbolic Android signing paths.")
    try:
        state = json.loads(marker.read_text(encoding="ascii"))
        if state["schema"] != 1 or set(state["sha256"]) != {str(KEYSTORE), str(PROPERTIES)}:
            raise ValueError
    except (ValueError, KeyError, TypeError):
        raise ValueError("The CI signing marker is invalid; no signing files were removed.") from None
    # Validate every remaining file before deleting anything. Locally replaced or
    # edited signing files are preserved, even when an old CI marker remains.
    for relative in (KEYSTORE, PROPERTIES):
        path = root / relative
        if path.is_symlink() or (path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != state["sha256"][str(relative)]):
            raise ValueError("CI signing files were changed; refusing to remove them.")
    for relative in (PROPERTIES, KEYSTORE):
        (root / relative).unlink(missing_ok=True)
    marker.unlink()
    if state.get("created_directory"):
        try:
            marker.parent.rmdir()
        except OSError:
            pass  # Other local files are never removed.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("configure", "cleanup"), nargs="?", default="configure")
    command = parser.parse_args().command
    try:
        if command == "cleanup":
            cleanup(ROOT)
        else:
            configure(ROOT, os.environ)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except OSError:
        print("Could not prepare or clean temporary Android signing files.", file=sys.stderr)
        return 1
    print(f"Temporary Android CI signing {command} completed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
