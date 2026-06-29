#!/bin/bash

# Runs every local test/validation suite for the repo.
#
# Usage:
#   ./scripts/test.sh            # run everything
#   ./scripts/test.sh api        # API only
#   ./scripts/test.sh app infra  # any combination of: api app infra
#
# One-time setup (API venv, APP node_modules, terraform providers) happens
# automatically on first run.
#
# Every step runs even if an earlier one fails; the script exits 1 if any
# step (setup, test, typecheck, build, or validation) failed.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=()
API_PYTHON_TOOLS_READY=0

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
  cd "$ROOT/API" || return 1

  if [[ "$API_PYTHON_TOOLS_READY" -eq 1 ]]; then
    return 0
  fi

  if [[ ! -x .venv/bin/python ]]; then
    echo "Creating API/.venv"
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
  run_check "$name" API/.venv/bin/pyright --project pyrightconfig.json "$@"
}

test_api() {
  ensure_api_python_tools || return 1
  cd "$ROOT/API" || return 1

  run_check "API compile" ./.venv/bin/python -m compileall -q src tests
  run_pyright "API pyright" API/src API/tests
  cd "$ROOT/API" || return 1
  run_check "API pytest" ./.venv/bin/python -m pytest
}

test_app() {
  cd "$ROOT/APP" || return 1

  if [[ ! -d node_modules ]]; then
    echo "Installing APP dependencies"
    run_check "APP dependency install" npm install || return 1
  fi

  run_check "APP Jest" env CI=true npm run test -- --watchAll=false --runInBand
  run_check "APP TypeScript" npx tsc --noEmit
  run_check "APP production build" npm run build
}

test_infra() {
  cd "$ROOT" || return 1

  if [[ ! -d OCI/terraform/.terraform || ! -f OCI/terraform/.terraform.lock.hcl ]]; then
    echo "Initializing Terraform providers"
    run_check "Terraform init" terraform -chdir=OCI/terraform init -backend=false -input=false || return 1
  fi
  run_check "Terraform format" terraform -chdir=OCI/terraform fmt -check
  run_check "Terraform validate" terraform -chdir=OCI/terraform validate

  for script in OCI/host/*.sh scripts/*.sh; do
    run_check "parse $script" bash -n "$script"
  done

  for template in OCI/terraform/*.tftpl; do
    run_check "parse $template" bash -n "$template"
  done

  run_check "Unbound forwards over DoT" grep -Fq 'forward-tls-upstream: yes' OCI/host/bootstrap.sh
  run_check "Unbound DoT cert bundle" grep -Fq 'tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"' OCI/host/bootstrap.sh
  run_check "Unbound DNSSEC trust anchor fallback" grep -Fq 'UNBOUND_TRUST_ANCHOR_LINE=' OCI/host/bootstrap.sh
  run_check "Unbound DNSSEC duplicate trust anchor guard" grep -Fq 'Unbound package config already declares /var/lib/unbound/root.key' OCI/host/bootstrap.sh
  run_check "Unbound DoT upstream Quad9" grep -Fq '9.9.9.9@853#dns.quad9.net' OCI/host/bootstrap.sh
  run_check "Unbound DoT upstream Mullvad" grep -Fq '194.242.2.2@853#dns.mullvad.net' OCI/host/bootstrap.sh
  run_check "Unbound DoT upstream DNS.SB" grep -Fq '185.222.222.222@853#dns.sb' OCI/host/bootstrap.sh
  run_check "Unbound no recursive root-hints override" sh -c '! grep -Fq "root-hints:" OCI/host/bootstrap.sh'
  run_check "Unbound no plaintext recursion fallback" grep -Fq 'forward-first: no' OCI/host/bootstrap.sh
  run_check "AdGuard upstream is local Unbound" grep -Fq '127.0.0.1:$UNBOUND_LISTEN_PORT' OCI/host/bootstrap.sh
  run_check "AdGuard DNSSEC enabled" grep -Fq 'enable_dnssec: true' OCI/host/bootstrap.sh

  run_check "Caddy release version format" grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$' OCI/caddy/VERSION
  run_check "Caddy Dockerfile target asset" grep -Fq 'cloudgateway-caddy-linux-arm64' OCI/caddy/Dockerfile
  run_check "Caddy Dockerfile rate limit module" grep -Fq 'github.com/mholt/caddy-ratelimit' OCI/caddy/Dockerfile

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

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(api app infra)
fi

for target in "${targets[@]}"; do
  case "$target" in
    api) run_step "API tests (pyright + pytest + compile)" test_api ;;
    app) run_step "APP tests + typecheck + build (jest + tsc + CRA)" test_app ;;
    infra) run_step "Infra validation (terraform + script parse)" test_infra ;;
    *)
      echo "Unknown target: $target (expected: api, app, infra)" >&2
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
