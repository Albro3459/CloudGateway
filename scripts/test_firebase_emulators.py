"""Run rules and API integration suites under one Firebase emulator lifetime."""

import ipaddress
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    environment = dict(os.environ)
    for name in ("FIREBASE_AUTH_EMULATOR_HOST", "FIRESTORE_EMULATOR_HOST"):
        value = environment.get(name, "")
        try:
            address = urlsplit("//" + value)
            host = address.hostname or ""
            is_local = host == "localhost" or ipaddress.ip_address(host).is_loopback
            valid = is_local and address.port is not None and not any((
                address.username, address.password, address.path, address.query, address.fragment,
            ))
        except ValueError:
            valid = False
        if not valid:
            print(f"{name} must identify a loopback emulator with an explicit port", file=sys.stderr)
            return 1
    environment["GCLOUD_PROJECT"] = "demo-cloudgateway"
    environment["GOOGLE_CLOUD_PROJECT"] = "demo-cloudgateway"
    environment.pop("GOOGLE_APPLICATION_CREDENTIALS", None)
    checks = [
        (["npm", "test"], ROOT / "Backend" / "Firebase"),
        ([sys.executable, "-m", "pytest", "-m", "emulator"], ROOT / "Backend" / "API"),
    ]
    failed = False
    for command, directory in checks:
        result = subprocess.run(command, cwd=directory, env=environment, check=False)
        failed = result.returncode != 0 or failed
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
