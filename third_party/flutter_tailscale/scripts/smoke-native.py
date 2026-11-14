#!/usr/bin/env python3
"""Exercise a real helper with disposable state and sanitized output only.

The optional --anonymous-login requests an official sign-in URL, but never
opens it, signs into an account, or touches an existing node directory.
"""
import argparse
import json
import pathlib
import queue
import re
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=pathlib.Path)
    parser.add_argument("--anonymous-login", action="store_true")
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 60:
        parser.error("timeout must be between 1 and 60 seconds")
    helper = args.helper.resolve()
    with tempfile.TemporaryDirectory(prefix="flutter-tailscale-check-") as directory:
        process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, encoding="utf-8", bufsize=1)
        responses = queue.Queue(maxsize=4)

        def read_responses():
            try:
                while True:
                    line = process.stdout.readline(1024 * 1024 + 2)
                    if not line:
                        responses.put(None)
                        return
                    if len(line.encode("utf-8")) > 1024 * 1024 + 1:
                        responses.put(None)
                        return
                    responses.put(json.loads(line))
            except (ValueError, OSError):
                responses.put(None)

        threading.Thread(target=read_responses, daemon=True).start()
        request_id = 0

        def request(method, **params):
            nonlocal request_id
            request_id += 1
            process.stdin.write(json.dumps({"id": request_id, "method": method,
                                            "params": params}) + "\n")
            process.stdin.flush()
            response = responses.get(timeout=25)
            if response is None or response.get("id") != request_id:
                raise RuntimeError("invalidResponse")
            if response.get("error"):
                code = response["error"].get("code", "operationFailed")
                raise RuntimeError(code if re.fullmatch(r"[A-Za-z0-9]{1,80}", code)
                                   else "operationFailed")
            return response["result"]

        owner = None
        try:
            initialized = request("initialize", stateDirectory=directory,
                                  hostname="flutter-tailscale-validation",
                                  protocolVersion=1)
            owner = initialized["ownerId"]
            state = request("status", ownerId=owner)
            if state["state"] != "stopped":
                raise RuntimeError("unexpectedInitialState")
            urls = set()
            if args.anonymous_login:
                state = request("login", ownerId=owner)
                deadline = time.monotonic() + args.timeout
                while True:
                    if state.get("authUrl"):
                        urls.add(state["authUrl"])
                        break
                    if time.monotonic() >= deadline:
                        break
                    time.sleep(1)
                    state = request("status", ownerId=owner)
                if not urls:
                    raise RuntimeError("authenticationUrlUnavailable")
            for path in pathlib.Path(directory).rglob("*"):
                if path.is_file() and "log" in path.name:
                    content = path.read_bytes()
                    if any(url.encode() in content for url in urls):
                        raise RuntimeError("authenticationUrlInLogs")
            logged_out = request("logout", ownerId=owner)
            if not logged_out.get("localCredentialsCleared"):
                raise RuntimeError("credentialCleanupFailed")
            request("dispose", ownerId=owner)
            owner = None
            print(json.dumps({"passed": True, "anonymousLogin": args.anonymous_login,
                              "authUrlPresent": bool(urls), "localCredentialsCleared": True,
                              "authUrlInLogs": False}))
        except (RuntimeError, OSError, ValueError, KeyError, queue.Empty) as error:
            code = str(error) if isinstance(error, RuntimeError) else type(error).__name__
            print(json.dumps({"passed": False, "errorCode": code}))
            raise SystemExit(1) from None
        finally:
            if owner is not None and process.poll() is None:
                try:
                    request("logout", ownerId=owner)
                    request("dispose", ownerId=owner)
                except Exception:
                    pass
            if process.poll() is None:
                process.stdin.close()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
