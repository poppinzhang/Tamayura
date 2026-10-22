#!/usr/bin/env python3
"""Publish a fully assembled preview release; never replace a published release."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


class ReleaseError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Do not forward the authorization header to a redirect destination."""

    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


class GitHubClient:
    def __init__(self, repository: str, token: str):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ReleaseError("GITHUB_REPOSITORY must be an owner/repository name.")
        if not token:
            raise ReleaseError("GH_TOKEN is required.")
        self.repository = repository
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, method: str, endpoint: str, payload=None, file: Path | None = None):
        host = "uploads.github.com" if file is not None else "api.github.com"
        url = f"https://{host}/repos/{self.repository}/{endpoint}"
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Tamayura-release-workflow",
        }
        stream = None
        try:
            if file is not None:
                stream = file.open("rb")
                data = stream
                headers["Content-Type"] = "application/octet-stream"
                headers["Content-Length"] = str(file.stat().st_size)
            else:
                data = json.dumps(payload).encode("utf-8") if payload is not None else None
                if data is not None:
                    headers["Content-Type"] = "application/json"
            request = urllib.request.Request(url, data=data, headers=headers, method=method)
            with self.opener.open(request, timeout=180) as response:
                body = response.read()
            return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            # A failed lookup is never evidence that a release does not exist.
            raise ReleaseError(f"GitHub {method} request failed (HTTP {error.code}).") from error
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.HTTPException) as error:
            raise ReleaseError("GitHub network request failed; the draft can be retried.") from error
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise ReleaseError("GitHub returned an invalid JSON response.") from error
        finally:
            if stream is not None:
                stream.close()

    def pages(self, endpoint: str):
        page = 1
        while True:
            entries = self.request("GET", f"{endpoint}?per_page=100&page={page}")
            if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
                raise ReleaseError("GitHub returned an invalid list response.")
            yield from entries
            if len(entries) < 100:
                return
            page += 1

    def tag_commit(self, tag: str) -> str:
        ref = self.request("GET", f"git/ref/tags/{urllib.parse.quote(tag, safe='')}")
        obj = ref.get("object", {}) if isinstance(ref, dict) else {}
        seen = set()
        while isinstance(obj, dict) and obj.get("type") == "tag":
            sha = obj.get("sha", "")
            if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha) or sha in seen or len(seen) >= 16:
                raise ReleaseError("The remote annotated tag is invalid.")
            seen.add(sha)
            annotated = self.request("GET", f"git/tags/{sha}")
            obj = annotated.get("object", {}) if isinstance(annotated, dict) else {}
        if not isinstance(obj, dict) or obj.get("type") != "commit" or not isinstance(obj.get("sha"), str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", obj["sha"]):
            raise ReleaseError("The remote tag does not resolve to a commit.")
        return obj["sha"]

    def find_release(self, tag: str):
        # The list endpoint includes drafts for an authenticated writer. Unlike
        # GET /releases/tags/:tag, it can find a failed draft on a later rerun.
        releases = [release for release in self.pages("releases") if release.get("tag_name") == tag]
        if len(releases) > 1:
            raise ReleaseError("Multiple releases use this tag; resolve them before retrying.")
        return releases[0] if releases else None


def asset_paths(directory: Path, tag: str) -> list[Path]:
    match = re.fullmatch(r"v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))", tag)
    if match is None:
        raise ReleaseError("The release tag must be vMAJOR.MINOR.PATCH.")
    version = match[1]
    names = [
        f"Tamayura-{version}-android.apk",
        f"Tamayura-{version}-macos.zip",
        f"Tamayura-{version}-windows-x64.zip",
        f"Tamayura-{version}-linux-x64.tar.gz",
        f"Tamayura-{version}-linux-arm64.tar.gz",
        "SHA256SUMS",
        "release.json",
    ]
    if not directory.is_dir() or directory.is_symlink():
        raise ReleaseError("The assembled release directory is missing or is a symlink.")
    entries = list(directory.iterdir())
    if {path.name for path in entries} != set(names):
        raise ReleaseError("The release directory must contain exactly the platform packages, SHA256SUMS and release.json.")
    if any(path.is_symlink() or not path.is_file() or path.stat().st_size == 0 for path in entries):
        raise ReleaseError("Release assets must be nonempty regular files, without symlinks.")
    return [directory / name for name in names]


def require_draft(release, tag: str, sha: str):
    if not isinstance(release, dict):
        raise ReleaseError("GitHub returned an invalid release response.")
    if release.get("draft") is not True:
        raise ReleaseError("This release is already published; refusing to change it.")
    if release.get("tag_name") != tag or release.get("target_commitish") != sha:
        raise ReleaseError("The existing draft does not target this release commit.")
    release_id = release.get("id")
    if not isinstance(release_id, int) or isinstance(release_id, bool) or release_id <= 0:
        raise ReleaseError("GitHub returned an invalid release identifier.")
    return release_id


def require_tag(client: GitHubClient, tag: str, sha: str):
    if client.tag_commit(tag) != sha:
        raise ReleaseError("The remote tag moved or does not match GITHUB_SHA; refusing to publish.")


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return f"sha256:{digest.hexdigest()}"


def publish(client: GitHubClient, tag: str, directory: Path, notes_path: Path, sha: str):
    paths = asset_paths(directory, tag)
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha):
        raise ReleaseError("GITHUB_SHA must identify the commit that was built.")
    notes = notes_path.read_text(encoding="utf-8")
    if not notes.strip():
        raise ReleaseError("The release notes file is empty.")
    require_tag(client, tag, sha)
    release = client.find_release(tag)
    metadata = {
        "tag_name": tag,
        "target_commitish": sha,
        "name": tag,
        "body": notes,
        "draft": True,
        "prerelease": True,
        "make_latest": "false",
    }
    if release is None:
        release = client.request("POST", "releases", payload=metadata)
    release_id = require_draft(release, tag, sha)
    endpoint = f"releases/{release_id}"
    expected = {path.name: path for path in paths}
    existing = list(client.pages(f"{endpoint}/assets"))
    if any(asset.get("name") not in expected for asset in existing):
        raise ReleaseError("The draft has unexpected attachments; refusing to remove them.")
    if len({asset.get("name") for asset in existing}) != len(existing):
        raise ReleaseError("The draft has duplicate attachment names.")
    # Only a still-unpublished draft can be updated or have attachments replaced.
    require_draft(client.request("GET", endpoint), tag, sha)
    client.request("PATCH", endpoint, payload=metadata)
    by_name = {asset["name"]: asset for asset in existing}
    for path in paths:
        require_draft(client.request("GET", endpoint), tag, sha)
        old = by_name.get(path.name)
        if old is not None:
            asset_id = old.get("id")
            if not isinstance(asset_id, int) or isinstance(asset_id, bool) or asset_id <= 0:
                raise ReleaseError("GitHub returned an invalid attachment identifier.")
            client.request("DELETE", f"releases/assets/{asset_id}")
        client.request("POST", f"{endpoint}/assets?name={urllib.parse.quote(path.name, safe='')}", file=path)
    uploaded = list(client.pages(f"{endpoint}/assets"))
    if len(uploaded) != len(paths) or {asset.get("name") for asset in uploaded} != set(expected):
        raise ReleaseError("The draft attachment list is incomplete; leaving it unpublished.")
    for asset in uploaded:
        path = expected[asset["name"]]
        if asset.get("state") != "uploaded" or asset.get("size") != path.stat().st_size:
            raise ReleaseError("A draft attachment is incomplete; leaving the release unpublished.")
        if asset.get("digest") is not None and asset["digest"] != file_digest(path):
            raise ReleaseError("A draft attachment digest does not match its local file.")
    require_tag(client, tag, sha)
    require_draft(client.request("GET", endpoint), tag, sha)
    result = client.request("PATCH", endpoint, payload={"draft": False, "prerelease": True, "make_latest": "false"})
    if not isinstance(result, dict) or result.get("draft") is not False or result.get("prerelease") is not True:
        raise ReleaseError("GitHub did not confirm the preview release publication.")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--assets-dir", required=True, type=Path)
    parser.add_argument("--notes", required=True, type=Path)
    args = parser.parse_args()
    try:
        client = GitHubClient(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GH_TOKEN", ""))
        publish(client, args.tag, args.assets_dir, args.notes, os.environ.get("GITHUB_SHA", ""))
    except ReleaseError as error:
        print(f"Release publication failed: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError):
        # File and decoding exceptions can include local paths or file contents.
        print("Release publication failed: could not read the release inputs or process the response.", file=sys.stderr)
        return 1
    print(f"Published preview release {args.tag} with all seven verified attachments.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
