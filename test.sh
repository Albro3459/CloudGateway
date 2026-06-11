#!/bin/bash

# Runs every local test/validation suite for the repo.
#
# Usage:
#   ./test.sh            # run everything
#   ./test.sh api        # API only
#   ./test.sh app infra  # any combination of: api app infra
#
# One-time setup (API venv, APP node_modules, terraform providers) happens
# automatically on first run.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/" && pwd)"
FAILURES=()

test_api() (
  set -e
  cd "$ROOT/API"

  if [[ ! -x .venv/bin/python ]]; then
    echo "Creating API/.venv"
    python3 -m venv .venv
    ./.venv/bin/python -m pip install --quiet --upgrade pip
  fi
  if ! ./.venv/bin/python -c "import pytest" >/dev/null 2>&1; then
    echo "Installing API dependencies"
    ./.venv/bin/python -m pip install --quiet -e '.[dev]'
  fi

  ./.venv/bin/python -m compileall -q cloudlaunch_api tests
  ./.venv/bin/python -m pytest
)

test_app() (
  set -e
  cd "$ROOT/APP"

  if [[ ! -d node_modules ]]; then
    echo "Installing APP dependencies"
    npm install
  fi

  CI=true npm test -- --watchAll=false
  npm run build
)

test_infra() (
  set -e
  cd "$ROOT"

  if [[ ! -d OCI/terraform/.terraform ]]; then
    terraform -chdir=OCI/terraform init -backend=false -input=false
  fi
  terraform -chdir=OCI/terraform validate

  for script in OCI/host/*.sh "$0"; do
    bash -n "$script"
    echo "parse ok: $script"
  done
)

run_step() {
  local name="$1"
  shift
  echo
  echo "============================================================"
  echo "==> $name"
  echo "============================================================"
  if "$@"; then
    echo "OK: $name"
  else
    echo "FAILED: $name" >&2
    FAILURES+=("$name")
  fi
}

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(api app infra)
fi

for target in "${targets[@]}"; do
  case "$target" in
    api) run_step "API tests (pytest + compile)" test_api ;;
    app) run_step "APP tests + build (jest + CRA)" test_app ;;
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