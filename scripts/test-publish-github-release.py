#!/usr/bin/env python3
"""Offline behavior tests for publishing and safely retrying release drafts."""

import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.parse


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("publish_github_release", Path(__file__).with_name("publish-github-release.py"))
PUBLISH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUBLISH)

SHA = "a" * 40
OTHER_SHA = "b" * 40
TAG = "v0.6.0"


class FakeGitHub(PUBLISH.GitHubClient):
    def __init__(self, release=None):
        super().__init__("example/Tamayura", "not-a-real-token")
        self.release = copy.deepcopy(release)
        self.assets = []
        self.calls = []
        self.tag_checks = 0
        self.move_tag_after = None
        self.annotated = False
        self.fail_upload = None
        self.fail_lookup = False
        self.bad_uploaded_asset = None

    def request(self, method, endpoint, payload=None, file=None):
        self.calls.append((method, endpoint, copy.deepcopy(payload)))
        if endpoint.startswith("git/ref/tags/"):
            self.tag_checks += 1
            sha = OTHER_SHA if self.move_tag_after is not None and self.tag_checks > self.move_tag_after else SHA
            return {"object": {"type": "tag" if self.annotated else "commit", "sha": sha}}
        if endpoint.startswith("git/tags/"):
            return {"object": {"type": "commit", "sha": SHA}}
        if endpoint.startswith("releases?per_page="):
            if self.fail_lookup:
                raise PUBLISH.ReleaseError("GitHub GET request failed (HTTP 503).")
            return [copy.deepcopy(self.release)] if self.release else []
        if method == "POST" and endpoint == "releases":
            self.release = dict(payload, id=10)
            return copy.deepcopy(self.release)
        if method == "GET" and endpoint == "releases/10":
            return copy.deepcopy(self.release)
        if method == "GET" and endpoint == "releases/latest":
            return copy.deepcopy(self.release)
        if method == "PATCH" and endpoint == "releases/10":
            self.release.update(payload)
            return copy.deepcopy(self.release)
        if method == "GET" and endpoint.startswith("releases/10/assets?per_page="):
            return copy.deepcopy(self.assets)
        if method == "DELETE" and endpoint.startswith("releases/assets/"):
            asset_id = int(endpoint.rsplit("/", 1)[1])
            self.assets = [asset for asset in self.assets if asset["id"] != asset_id]
            return None
        if method == "POST" and endpoint.startswith("releases/10/assets?name="):
            name = urllib.parse.parse_qs(urllib.parse.urlsplit(endpoint).query)["name"][0]
            if name == self.fail_upload:
                raise PUBLISH.ReleaseError("Simulated upload failure.")
            asset = {"id": 100 + len(self.calls), "name": name, "size": file.stat().st_size,
                     "state": "uploaded", "digest": PUBLISH.file_digest(file)}
            if self.bad_uploaded_asset is not None:
                asset.update(self.bad_uploaded_asset)
            self.assets.append(asset)
            return asset
        raise AssertionError(f"Unexpected request: {method} {endpoint}")


def draft(**overrides):
    return dict({"id": 10, "tag_name": TAG, "target_commitish": SHA, "draft": True, "prerelease": True}, **overrides)


class PublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.assets = self.root / "release"
        self.assets.mkdir()
        for name in ["Tamayura-0.6.0-android.apk", "Tamayura-0.6.0-macos.zip", "Tamayura-0.6.0-windows-x64.zip",
                     "Tamayura-0.6.0-linux-x64.tar.gz", "Tamayura-0.6.0-linux-arm64.tar.gz", "SHA256SUMS", "release.json"]:
            (self.assets / name).write_bytes(f"test data for {name}\n".encode())
        (self.assets / "release.json").write_text(json.dumps({"tag": TAG, "version": TAG[1:], "release_type": "release"}), encoding="utf-8")
        self.notes = self.root / "notes.md"
        self.notes.write_text("# Release\n\nChanges and known limitations.\n", encoding="utf-8")

    def publish(self, client):
        return PUBLISH.publish(client, TAG, self.assets, self.notes, SHA)

    def assert_not_published(self, client):
        self.assertFalse(any(payload is not None and payload.get("draft") is False for _, _, payload in client.calls))

    def test_creates_stable_draft_uploads_all_assets_then_publishes_as_latest(self):
        client = FakeGitHub()
        result = self.publish(client)
        self.assertIs(result["draft"], False)
        self.assertIs(result["prerelease"], False)
        self.assertEqual(result["make_latest"], "true")
        self.assertEqual(result["body"], self.notes.read_text())
        self.assertEqual({asset["name"] for asset in client.assets}, {path.name for path in self.assets.iterdir()})
        self.assertEqual(client.tag_checks, 2)
        self.assertEqual(client.calls[-2], ("PATCH", "releases/10", {"draft": False, "prerelease": False, "make_latest": "true"}))
        self.assertEqual(client.calls[-1], ("GET", "releases/latest", None))
        metadata = next(payload for method, endpoint, payload in client.calls if method == "POST" and endpoint == "releases")
        self.assertIs(metadata["draft"], True)
        self.assertIs(metadata["prerelease"], False)
        self.assertEqual(metadata["make_latest"], "false")

    def test_existing_preview_draft_becomes_stable_before_publication(self):
        client = FakeGitHub(draft())
        self.publish(client)
        updates = [payload for method, _, payload in client.calls if method == "PATCH"]
        self.assertIs(updates[0]["draft"], True)
        self.assertIs(updates[0]["prerelease"], False)
        self.assertIs(client.release["prerelease"], False)

    def test_manifest_must_agree_with_stable_release_before_network_access(self):
        manifest_path = self.assets / "release.json"
        for override in ({"release_type": "prerelease"}, {"release_type": None}, {"tag": "v0.5.0"}, {"version": "0.5.0"}):
            with self.subTest(override=override):
                manifest_path.write_text(json.dumps({"tag": TAG, "version": TAG[1:], "release_type": "release", **override}), encoding="utf-8")
                client = FakeGitHub()
                with self.assertRaisesRegex(PUBLISH.ReleaseError, "stable release"):
                    self.publish(client)
                self.assertEqual(client.calls, [])

    def test_publication_response_must_confirm_stable_tag_and_commit(self):
        for override in ({"prerelease": True}, {"draft": True}, {"tag_name": "v0.5.0"}, {"target_commitish": OTHER_SHA}):
            with self.subTest(override=override):
                client = FakeGitHub()
                original_request = client.request

                def request(method, endpoint, payload=None, file=None):
                    result = original_request(method, endpoint, payload, file)
                    if payload is not None and payload.get("draft") is False:
                        result.update(override)
                    return result

                client.request = request
                with self.assertRaisesRegex(PUBLISH.ReleaseError, "did not confirm the stable release"):
                    self.publish(client)

    def test_latest_response_must_identify_the_published_stable_release(self):
        for override in ({"id": 11}, {"tag_name": "v0.5.0"}, {"draft": True}, {"prerelease": True}):
            with self.subTest(override=override):
                client = FakeGitHub()
                original_request = client.request

                def request(method, endpoint, payload=None, file=None):
                    result = original_request(method, endpoint, payload, file)
                    if endpoint == "releases/latest":
                        result.update(override)
                    return result

                client.request = request
                with self.assertRaisesRegex(PUBLISH.ReleaseError, "was published, but GitHub did not confirm it as latest"):
                    self.publish(client)
                self.assertIs(client.release["draft"], False)
                self.assertEqual(client.calls[-1], ("GET", "releases/latest", None))
                self.assertEqual(sum(payload is not None and payload.get("draft") is False for _, _, payload in client.calls), 1)

    def test_latest_lookup_failure_reports_publication_without_retrying_mutations(self):
        client = FakeGitHub()
        original_request = client.request

        def request(method, endpoint, payload=None, file=None):
            result = original_request(method, endpoint, payload, file)
            if endpoint == "releases/latest":
                raise PUBLISH.ReleaseError("GitHub GET request failed (HTTP 503).")
            return result

        client.request = request
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "was published, but its latest status could not be verified"):
            self.publish(client)
        self.assertIs(client.release["draft"], False)
        self.assertEqual(client.calls[-1], ("GET", "releases/latest", None))

    def test_existing_published_release_is_never_modified(self):
        client = FakeGitHub(draft(draft=False))
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "already published"):
            self.publish(client)
        self.assertTrue(all(method == "GET" for method, _, _ in client.calls))

    def test_failed_upload_leaves_draft_and_rerun_replaces_partial_assets(self):
        client = FakeGitHub()
        client.fail_upload = "Tamayura-0.6.0-windows-x64.zip"
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "upload failure"):
            self.publish(client)
        self.assertIs(client.release["draft"], True)
        self.assertEqual(len(client.assets), 2)
        self.assert_not_published(client)
        client.fail_upload = None
        self.publish(client)
        self.assertEqual(len(client.assets), len(list(self.assets.iterdir())))
        self.assertEqual(sum(method == "POST" and endpoint == "releases" for method, endpoint, _ in client.calls), 1)
        self.assertEqual(sum(method == "DELETE" for method, _, _ in client.calls), 2)

    def test_remote_tag_mismatch_blocks_even_draft_creation(self):
        client = FakeGitHub()
        client.move_tag_after = 0
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "tag moved"):
            self.publish(client)
        self.assertIsNone(client.release)

    def test_tag_moved_during_upload_blocks_publication(self):
        client = FakeGitHub()
        client.move_tag_after = 1
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "tag moved"):
            self.publish(client)
        self.assertEqual(len(client.assets), len(list(self.assets.iterdir())))
        self.assert_not_published(client)

    def test_annotated_tag_is_resolved_to_its_commit(self):
        client = FakeGitHub()
        client.annotated = True
        self.publish(client)
        self.assertEqual(sum(endpoint.startswith("git/tags/") for _, endpoint, _ in client.calls), 2)

    def test_lookup_network_error_does_not_create_or_publish_release(self):
        client = FakeGitHub()
        client.fail_lookup = True
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "HTTP 503"):
            self.publish(client)
        self.assertIsNone(client.release)
        self.assertTrue(all(method == "GET" for method, _, _ in client.calls))

    def test_draft_for_different_commit_is_preserved(self):
        client = FakeGitHub(draft(target_commitish=OTHER_SHA))
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "does not target"):
            self.publish(client)
        self.assertTrue(all(method == "GET" for method, _, _ in client.calls))

    def test_unexpected_remote_attachment_is_not_removed(self):
        client = FakeGitHub(draft())
        client.assets = [{"id": 7, "name": "maintainer-notes.txt"}]
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "unexpected attachments"):
            self.publish(client)
        self.assertTrue(all(method == "GET" for method, _, _ in client.calls))

    def test_local_extra_file_missing_file_empty_file_and_directory_are_rejected(self):
        for kind in ("extra", "missing", "empty", "directory"):
            with self.subTest(kind=kind):
                changed = self.assets / ("extra.txt" if kind == "extra" else "release.json")
                original = changed.read_bytes() if changed.exists() else None
                try:
                    if kind == "extra":
                        changed.write_text("not an attachment")
                    elif kind == "missing":
                        changed.unlink()
                    elif kind == "empty":
                        changed.write_bytes(b"")
                    else:
                        changed.unlink()
                        changed.mkdir()
                    client = FakeGitHub()
                    with self.assertRaises(PUBLISH.ReleaseError):
                        self.publish(client)
                    self.assertEqual(client.calls, [])
                finally:
                    if changed.is_dir():
                        changed.rmdir()
                    if original is None:
                        changed.unlink(missing_ok=True)
                    else:
                        changed.write_bytes(original)

    def test_local_symlink_is_rejected_before_network_access(self):
        target = self.assets / "release.json"
        target.unlink()
        try:
            target.symlink_to(self.notes)
        except OSError:
            self.skipTest("This host does not permit symlink creation")
        client = FakeGitHub()
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "without symlinks"):
            self.publish(client)
        self.assertEqual(client.calls, [])

    def test_invalid_remote_size_state_and_digest_leave_draft_unpublished(self):
        for override in ({"size": 0}, {"state": "starter"}, {"digest": "sha256:wrong"}):
            with self.subTest(override=override):
                client = FakeGitHub()
                client.bad_uploaded_asset = override
                with self.assertRaises(PUBLISH.ReleaseError):
                    self.publish(client)
                self.assert_not_published(client)

    def test_manual_publication_during_upload_blocks_replacement(self):
        client = FakeGitHub(draft())
        original_request = client.request

        def request(method, endpoint, payload=None, file=None):
            response = original_request(method, endpoint, payload, file)
            if file is not None:
                client.release["draft"] = False
            return response

        client.request = request
        with self.assertRaisesRegex(PUBLISH.ReleaseError, "already published"):
            self.publish(client)
        self.assertEqual(len(client.assets), 1)
        self.assert_not_published(client)


class ClientTests(unittest.TestCase):
    def test_http_errors_including_404_are_not_treated_as_absence(self):
        client = PUBLISH.GitHubClient("example/Tamayura", "secret-token")
        for code in (401, 403, 404, 429, 500):
            with self.subTest(code=code):
                failure = urllib.error.HTTPError("https://api.github.com/", code, "failure", {}, io.BytesIO(b"private details"))
                with mock.patch.object(client.opener, "open", side_effect=failure):
                    with self.assertRaisesRegex(PUBLISH.ReleaseError, f"HTTP {code}") as error:
                        client.find_release(TAG)
                self.assertNotIn("secret-token", str(error.exception))
                self.assertNotIn("private details", str(error.exception))

    def test_network_error_is_reported_without_sensitive_details(self):
        client = PUBLISH.GitHubClient("example/Tamayura", "secret-token")
        with mock.patch.object(client.opener, "open", side_effect=urllib.error.URLError("private connection details")):
            with self.assertRaisesRegex(PUBLISH.ReleaseError, "network request failed") as error:
                client.find_release(TAG)
        self.assertNotIn("private connection details", str(error.exception))

    def test_find_release_paginates_and_includes_drafts(self):
        client = PUBLISH.GitHubClient("example/Tamayura", "unused")
        pages = [[{"tag_name": f"v0.0.{index}"} for index in range(100)], [draft()]]
        with mock.patch.object(client, "request", side_effect=pages) as request:
            self.assertEqual(client.find_release(TAG), draft())
        self.assertEqual(request.call_args_list[-1], mock.call("GET", "releases?per_page=100&page=2"))

    def test_annotated_tag_cycle_is_rejected(self):
        client = PUBLISH.GitHubClient("example/Tamayura", "unused")
        with mock.patch.object(client, "request", return_value={"object": {"type": "tag", "sha": SHA}}):
            with self.assertRaisesRegex(PUBLISH.ReleaseError, "annotated tag is invalid"):
                client.tag_commit(TAG)

    def test_invalid_remote_ref_and_list_responses_fail_closed(self):
        client = PUBLISH.GitHubClient("example/Tamayura", "unused")
        for response in (None, [], {"object": None}, {"object": {"type": "tree", "sha": SHA}}):
            with self.subTest(response=response):
                with mock.patch.object(client, "request", return_value=response):
                    with self.assertRaises(PUBLISH.ReleaseError):
                        client.tag_commit(TAG)
        with mock.patch.object(client, "request", return_value=[None]):
            with self.assertRaisesRegex(PUBLISH.ReleaseError, "invalid list"):
                client.find_release(TAG)

    def test_duplicate_releases_are_rejected(self):
        client = PUBLISH.GitHubClient("example/Tamayura", "unused")
        with mock.patch.object(client, "request", return_value=[draft(), draft(draft=False)]):
            with self.assertRaisesRegex(PUBLISH.ReleaseError, "Multiple releases"):
                client.find_release(TAG)

    def test_redirect_cannot_forward_authorization(self):
        request = urllib.request.Request("https://api.github.com/", headers={"Authorization": "Bearer unused"})
        self.assertIsNone(PUBLISH.NoRedirect().redirect_request(request, None, 302, "Moved", {}, "https://different.invalid/"))

    def test_cli_file_and_decode_errors_do_not_print_private_details(self):
        arguments = ["publish-github-release.py", "--tag", TAG, "--assets-dir", "unused", "--notes", "unused"]
        for error in (FileNotFoundError("private input path"), ValueError("private file contents")):
            with self.subTest(error=type(error).__name__):
                output = io.StringIO()
                with mock.patch.object(sys, "argv", arguments), mock.patch.object(PUBLISH, "GitHubClient"), mock.patch.object(PUBLISH, "publish", side_effect=error), contextlib.redirect_stderr(output):
                    self.assertEqual(PUBLISH.main(), 1)
                self.assertIn("could not read the release inputs", output.getvalue())
                self.assertNotIn("private", output.getvalue())

    def test_upload_streams_to_expected_host_with_explicit_content_length(self):
        client = PUBLISH.GitHubClient("example/Tamayura", "unused")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "example.zip"
            path.write_bytes(b"package bytes")
            response = mock.MagicMock()
            response.__enter__.return_value.read.return_value = json.dumps({"id": 1}).encode()

            def open_request(request, timeout):
                self.assertEqual(request.full_url, "https://uploads.github.com/repos/example/Tamayura/releases/10/assets?name=example.zip")
                self.assertEqual(request.headers["Content-length"], "13")
                self.assertEqual(request.data.read(), b"package bytes")
                return response

            with mock.patch.object(client.opener, "open", side_effect=open_request):
                self.assertEqual(client.request("POST", "releases/10/assets?name=example.zip", file=path), {"id": 1})


if __name__ == "__main__":
    unittest.main()
