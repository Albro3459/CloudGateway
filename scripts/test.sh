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

test_api() {
  cd "$ROOT/API" || return 1

  if [[ ! -x .venv/bin/python ]]; then
    echo "Creating API/.venv"
    run_check "API venv create" python3 -m venv .venv || return 1
    run_check "API pip upgrade" ./.venv/bin/python -m pip install --quiet --upgrade pip || return 1
  fi
  # Upsert dependencies from pyproject every run (like `npm i`) so new deps are
  # picked up on an existing venv. pip is a no-op when everything is satisfied.
  echo "Syncing API dependencies"
  run_check "API dependency sync" ./.venv/bin/python -m pip install --quiet -e '.[dev]' || return 1

  run_check "API compile" ./.venv/bin/python -m compileall -q src tests
  run_check "API pyright" ./.venv/bin/pyright --project ../pyrightconfig.json
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
  run_check "Terraform validate" terraform -chdir=OCI/terraform validate

  for script in OCI/host/*.sh scripts/*.sh; do
    run_check "parse $script" bash -n "$script"
  done

  run_check "preflight compile" python3 -m py_compile scripts/terraform-preflight.py
  run_check "preflight tests" python3 -m unittest scripts/test_terraform_preflight.py
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
