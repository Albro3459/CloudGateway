"""Exercise device authorization without a native app, keeping tokens in memory."""

import argparse
import base64
import hashlib
import json
import secrets
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post(url: str, body: dict[str, Any]) -> tuple[int, dict[str, Any], int]:
    request = Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    try:
        with build_opener(NoRedirects()).open(request, timeout=20) as response:
            return response.status, json.load(response), 0
    except HTTPError as error:
        try:
            data = json.load(error)
        except (ValueError, UnicodeError):
            data = {}
        retry_after = error.headers.get("Retry-After", "0")
        return error.code, data, int(retry_after) if retry_after.isdecimal() else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-origin", required=True, help="API origin, such as https://api.gocloudlaunch.com")
    parser.add_argument("--firebase-api-key", required=True, help="Public Firebase web API key")
    parser.add_argument("--device-name", default="Device authorization test client")
    args = parser.parse_args()
    origin = args.api_origin.rstrip("/")
    parts = urlsplit(origin)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.path or parts.query or parts.fragment:
        parser.error("Use an HTTPS API origin without a path, credentials, query, or fragment")

    secret_bytes = secrets.token_bytes(32)
    secret = base64.urlsafe_b64encode(secret_bytes).decode().rstrip("=")
    status, created, _ = post(f"{origin}/api/device/code", {
        "deviceSecretHash": hashlib.sha256(secret_bytes).hexdigest(),
        "deviceName": args.device_name,
    })
    if status != 201:
        print("Could not start device authorization. Check API configuration and creation limits.")
        return 1
    print(f"Code: {created['userCode']}")
    print(f"Open: {created['verificationUriComplete']}")
    deadline = time.monotonic() + created["expiresIn"]
    interval = created["interval"]
    while time.monotonic() < deadline:
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
        if time.monotonic() >= deadline:
            break
        status, result, retry_after = post(f"{origin}/api/device/token", {
            "deviceRequestId": created["deviceRequestId"], "deviceSecret": secret,
        })
        if status == 202:
            continue
        if status == 429:
            interval = max(interval, retry_after)
            continue
        if status != 200:
            print("Device authorization ended. Start a new attempt if needed.")
            return 1
        token = result.pop("customToken")
        exchange_url = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?" + urlencode({"key": args.firebase_api_key})
        status, session, _ = post(exchange_url, {"token": token, "returnSecureToken": True})
        del token
        if status != 200:
            print("Firebase sign-in failed. Start a fresh attempt after checking staging configuration.")
            return 1
        print("Firebase sign-in succeeded. Verify account permissions separately in staging.")
        session.clear()
        return 0
    print("Device authorization expired.")
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Device authorization cancelled.")
        raise SystemExit(1) from None
    except (URLError, TimeoutError, ValueError, KeyError, TypeError):
        print("Device authorization failed. Start a fresh attempt after checking connectivity and configuration.")
        raise SystemExit(1) from None
