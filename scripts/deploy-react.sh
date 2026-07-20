#!/usr/bin/env bash

# Build and publish the React site, then commit the npm version bump.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_JSON="$ROOT/Frontend/Web/package.json"

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes before deploying." >&2
  git -C "$ROOT" status --short >&2
  exit 1
fi

cd "$ROOT/Frontend/Web"
npm run deploy

VERSION="$(python3 - "$PACKAGE_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["version"])
PY
)"

if [[ "$(git -C "$ROOT" status --porcelain)" != " M Frontend/Web/package.json" ]]; then
  echo "React deployment changed files other than package.json; refusing to commit." >&2
  git -C "$ROOT" status --short >&2
  exit 1
fi

git -C "$ROOT" add "$PACKAGE_JSON"
git -C "$ROOT" commit -m "Deploy React v${VERSION}"
echo "Published React v${VERSION}"
