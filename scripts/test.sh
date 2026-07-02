#!/bin/bash

# Runs every local test/validation suite for the repo.
#
# Usage:
#   ./scripts/test.sh            # run everything
#   ./scripts/test.sh api        # API only
#   ./scripts/test.sh apple      # Apple tests + unsigned no-device iOS build
#   ./scripts/test.sh apple --signed  # Apple tests + signed no-device iOS build
#   ./scripts/test.sh web infra  # any combination of: api web infra apple firebase
#
# One-time setup (API venv, Web node_modules, terraform providers) happens
# automatically on first run.
#
# Every step runs even if an earlier one fails; the script exits 1 if any
# step (setup, test, typecheck, build, or validation) failed.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=()
API_PYTHON_TOOLS_READY=0
APPLE_SIGNED=0

# Run a named command, recording it in FAILURES on failure. Never aborts, so
# later steps still run. Returns the command's exit code.
run_check() {
  local name="$1"
  shift
  echo "--- $name ---"
  if "$@"; then
    echo "OK: $name"
    return 0
  fi
  echo "FAILED: $name" >&2
  FAILURES+=("$name")
  return 1
}

ensure_api_python_tools() {
  cd "$ROOT/Backend/API" || return 1

  if [[ "$API_PYTHON_TOOLS_READY" -eq 1 ]]; then
    return 0
  fi

  if [[ ! -x .venv/bin/python ]]; then
    echo "Creating Backend/API/.venv"
    run_check "API venv create" python3 -m venv .venv || return 1
    run_check "API pip upgrade" ./.venv/bin/python -m pip install --quiet --upgrade pip || return 1
  fi
  # Upsert dependencies from pyproject every run (like `npm i`) so new deps are
  # picked up on an existing venv. pip is a no-op when everything is satisfied.
  echo "Syncing API dependencies"
  run_check "API dependency sync" ./.venv/bin/python -m pip install --quiet -e '.[dev]' || return 1
  API_PYTHON_TOOLS_READY=1
}

run_pyright() {
  local name="$1"
  shift
  cd "$ROOT" || return 1
  ensure_api_python_tools || return 1
  cd "$ROOT" || return 1
  run_check "$name" Backend/API/.venv/bin/pyright --project pyrightconfig.json "$@"
}

test_api() {
  ensure_api_python_tools || return 1
  cd "$ROOT/Backend/API" || return 1

  run_check "API compile" ./.venv/bin/python -m compileall -q src tests
  run_pyright "API pyright" Backend/API/src Backend/API/tests
  cd "$ROOT/Backend/API" || return 1
  run_check "API pytest" ./.venv/bin/python -m pytest
}

test_web() {
  cd "$ROOT/Frontend/Web" || return 1

  if [[ ! -d node_modules ]]; then
    echo "Installing Web dependencies"
    run_check "Web dependency install" npm install || return 1
  fi

  run_check "Web Jest" env CI=true npm run test -- --watchAll=false --runInBand
  run_check "Web TypeScript" npx tsc --noEmit
  run_check "Web production build" npm run build
}

test_firebase() {
  cd "$ROOT/Backend/Firebase" || return 1

  if [[ ! -d node_modules ]]; then
    echo "Installing Firebase rules-test dependencies"
    run_check "Firebase dependency install" npm install || return 1
  fi

  run_firestore_rules_tests() {
    env FIREBASE_CLI_DISABLE_UPDATE_CHECK=true npm exec -- firebase emulators:exec --only firestore --project demo-cloudgateway "npm test" 2> >(
      grep -Ev "^(lsof: WARNING: can't stat\\(\\)|      Output information may be incomplete\\.|      assuming \"dev=)" >&2
    )
  }

  # emulators:exec boots the Firestore emulator, runs the rules tests, and tears
  # it down. A demo- project keeps it fully offline (no credentials).
  run_check "Firestore rules tests" run_firestore_rules_tests
}

test_apple() {
  cd "$ROOT" || return 1

  run_check "Apple CloudGatewayKit tests" swift test --package-path Frontend/Apple/CloudGatewayKit
  run_check "Apple iOS project list" xcodebuild -list -project Frontend/Apple/iOS/CloudGateway.xcodeproj

  if [[ "$APPLE_SIGNED" -eq 1 ]]; then
    run_check "Apple signed no-device iOS build" \
      xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj \
        -scheme CloudGateway \
        -destination generic/platform=iOS \
        build
  else
    run_check "Apple unsigned no-device iOS build" \
      xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj \
        -scheme CloudGateway \
        -destination generic/platform=iOS \
        CODE_SIGNING_ALLOWED=NO \
        build
  fi

  # Host-less view-model tests. Runs on a simulator because the app scheme cannot
  # (the packet-tunnel extension links a device-only WireGuard lib). Override the
  # simulator with APPLE_TEST_SIMULATOR if "iPhone 17" is not installed.
  local ios_sim="${APPLE_TEST_SIMULATOR:-iPhone 17}"
  run_check "Apple iOS view-model tests" \
    xcodebuild test \
      -project Frontend/Apple/iOS/CloudGateway.xcodeproj \
      -scheme CloudGatewayTests \
      -destination "platform=iOS Simulator,name=$ios_sim"
}

test_infra() {
  cd "$ROOT" || return 1

  if [[ ! -d Infrastructure/OCI/terraform/.terraform || ! -f Infrastructure/OCI/terraform/.terraform.lock.hcl ]]; then
    echo "Initializing Terraform providers"
    run_check "Terraform init" terraform -chdir=Infrastructure/OCI/terraform init -backend=false -input=false || return 1
  fi
  run_check "Terraform format" terraform -chdir=Infrastructure/OCI/terraform fmt -check
  run_check "Terraform validate" terraform -chdir=Infrastructure/OCI/terraform validate

  for script in Infrastructure/OCI/host/*.sh scripts/*.sh; do
    run_check "parse $script" bash -n "$script"
  done

  for template in Infrastructure/OCI/terraform/*.tftpl; do
    run_check "parse $template" bash -n "$template"
  done

  run_check "Unbound forwards over DoT" grep -Fq 'forward-tls-upstream: yes' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DoT cert bundle" grep -Fq 'tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DNSSEC trust anchor fallback" grep -Fq 'UNBOUND_TRUST_ANCHOR_LINE=' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DNSSEC is required" grep -Fq 'DNSSEC validation requires /var/lib/unbound/root.key' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DNSSEC no fail-soft" sh -c '! grep -Fq "continuing without DNSSEC validation" Infrastructure/OCI/host/bootstrap.sh'
  run_check "Unbound DNSSEC duplicate trust anchor guard" grep -Fq 'Existing Unbound config already declares /var/lib/unbound/root.key' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DoT upstream Quad9" grep -Fq '9.9.9.9@853#dns.quad9.net' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DoT upstream Mullvad" grep -Fq '194.242.2.2@853#dns.mullvad.net' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound DoT upstream DNS.SB" grep -Fq '185.222.222.222@853#dns.sb' Infrastructure/OCI/host/bootstrap.sh
  run_check "Unbound no recursive root-hints override" sh -c '! grep -Fq "root-hints:" Infrastructure/OCI/host/bootstrap.sh'
  run_check "Unbound no plaintext recursion fallback" grep -Fq 'forward-first: no' Infrastructure/OCI/host/bootstrap.sh
  run_check "AdGuard upstream is local Unbound" grep -Fq '127.0.0.1:$UNBOUND_LISTEN_PORT' Infrastructure/OCI/host/bootstrap.sh
  run_check "AdGuard DNSSEC enabled" grep -Fq 'enable_dnssec: true' Infrastructure/OCI/host/bootstrap.sh

  run_check "Caddy release version format" grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$' Infrastructure/OCI/caddy/VERSION
  run_check "Caddy Dockerfile target asset" grep -Fq 'cloudgateway-caddy-linux-arm64' Infrastructure/OCI/caddy/Dockerfile
  run_check "Caddy Dockerfile rate limit module" grep -Fq 'github.com/mholt/caddy-ratelimit' Infrastructure/OCI/caddy/Dockerfile

  run_pyright "Terraform preflight pyright" scripts/terraform-preflight.py scripts/test_terraform_preflight.py
  run_check "Terraform preflight compile" python3 -m py_compile scripts/terraform-preflight.py
  run_check "Terraform  preflight tests" python3 -m unittest scripts/test_terraform_preflight.py

  run_pyright "Firestore backup pyright" scripts/backup_firestore.py scripts/test_backup_firestore.py
  run_check "Firestore backup compile" python3 -m py_compile scripts/backup_firestore.py scripts/test_backup_firestore.py
  run_check "Firestore backup tests" python3 -m unittest scripts/test_backup_firestore.py
}

run_step() {
  local name="$1"
  shift
  echo
  echo "============================================================"
  echo "==> $name"
  echo "============================================================"
  # Run directly (not in a subshell) so the step's run_check failures land in
  # FAILURES. Each target cd's to its own dir first, so a leaked cwd is fine.
  # Judge the target by whether it added any failures.
  local before=${#FAILURES[@]}
  "$@"
  if [[ ${#FAILURES[@]} -gt $before ]]; then
    echo "FAILED: $name" >&2
  else
    echo "OK: $name"
  fi
}

targets=()
for arg in "$@"; do
  case "$arg" in
    --signed) APPLE_SIGNED=1 ;;
    *) targets+=("$arg") ;;
  esac
done

if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(api web infra firebase)
fi

for target in "${targets[@]}"; do
  case "$target" in
    api) run_step "API tests (pyright + pytest + compile)" test_api ;;
    web|app) run_step "Web tests + typecheck + build (jest + tsc + CRA)" test_web ;;
    apple) run_step "Apple tests + no-device iOS build" test_apple ;;
    infra) run_step "Infra validation (terraform + script parse)" test_infra ;;
    firebase) run_step "Firestore rules tests (emulator)" test_firebase ;;
    *)
      echo "Unknown target: $target (expected: api, web, apple, infra, firebase; optional flag: --signed)" >&2
      exit 2
      ;;
  esac
done

echo
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "FAILED: ${FAILURES[*]}"
  exit 1
fi
echo "All checks passed."
exit 0
