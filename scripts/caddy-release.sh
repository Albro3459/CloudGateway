#!/usr/bin/env bash

# Build and publish the prebuilt CloudGateway Caddy binary.
#
# Usage:
#   ./scripts/caddy-release.sh [--dry-run]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CADDY_DIR="$ROOT/Infrastructure/OCI/caddy"
VERSION_FILE="$CADDY_DIR/VERSION"
TFDIR="$ROOT/Infrastructure/OCI/terraform"
ASSET_NAME="cloudgateway-caddy-linux-arm64"
TAG_PREFIX="caddy-v"

CADDY_VERSION="v2.8.4"
CADDY_RATE_LIMIT_MODULE="github.com/mholt/caddy-ratelimit"
CADDY_RATE_LIMIT_MODULE_ID="http.handlers.rate_limit"
CADDY_RELEASE_REGIONS=(chicago sanjose)

DRY_RUN=false
REGION_IDS=()
VARFILES=()

usage() {
  echo "usage: $0 [--dry-run]" >&2
}

require_cmd() {
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

require_clean_tree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean. Commit or discard changes before creating a Caddy release:" >&2
    git status --short >&2
    exit 1
  fi
}

require_branch_synced() {
  local upstream local_head upstream_head

  if ! upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    echo "Current branch has no upstream. Push it and set upstream before releasing." >&2
    exit 1
  fi

  git fetch --quiet
  local_head="$(git rev-parse HEAD)"
  upstream_head="$(git rev-parse "$upstream")"
  if [[ "$local_head" != "$upstream_head" ]]; then
    echo "Current branch must match $upstream before releasing." >&2
    git status --short --branch >&2
    exit 1
  fi
}

validate_version() {
  local version="$1"

  if [[ ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    echo "Invalid version '$version'. Expected X.Y.Z." >&2
    exit 1
  fi
}

next_patch_version() {
  local latest_tag current_version major minor patch

  latest_tag="$(git tag -l "${TAG_PREFIX}*" | sort -V | tail -n1)"
  if [[ -z "$latest_tag" ]]; then
    current_version="$(tr -d '[:space:]' < "$VERSION_FILE")"
    validate_version "$current_version"
    if [[ "$current_version" == "0.0.0" ]]; then
      echo "1.0.0"
    else
      echo "$current_version"
    fi
    return
  fi

  current_version="${latest_tag#"$TAG_PREFIX"}"
  validate_version "$current_version"
  IFS=. read -r major minor patch <<< "$current_version"
  echo "${major}.${minor}.$((patch + 1))"
}

set_tfvar() {
  local varfile="$1" name="$2" value="$3" tmp

  if grep -q "^[[:space:]]*${name}[[:space:]]*=" "$varfile"; then
    tmp="$(mktemp)"
    sed "s|^[[:space:]]*${name}[[:space:]]*=.*|${name} = \"${value}\"|" "$varfile" > "$tmp"
    mv "$tmp" "$varfile"
  else
    printf '\n%s = "%s"\n' "$name" "$value" >> "$varfile"
  fi
}

format_varfiles() {
  local varfile

  for varfile in "$@"; do
    terraform -chdir="$TFDIR" fmt "$(basename "$varfile")" >/dev/null
  done
}

update_region_tfvars() {
  local i

  for i in "${!REGION_IDS[@]}"; do
    echo "==> Setting caddy_binary_tag and caddy_binary_sha256 in ${REGION_IDS[$i]}.terraform.tfvars"
    set_tfvar "${VARFILES[$i]}" "caddy_binary_tag" "$CADDY_TAG"
    set_tfvar "${VARFILES[$i]}" "caddy_binary_sha256" "$CADDY_SHA256"
  done
  format_varfiles "${VARFILES[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      usage
      exit 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

for region in "${CADDY_RELEASE_REGIONS[@]}"; do
  case "$region" in
    us-*-*) region_id="$region" ;;
    *)      region_id="us-${region}-1" ;;
  esac

  REGION_IDS+=("$region_id")
  VARFILES+=("$TFDIR/${region_id}.terraform.tfvars")
done

for i in "${!REGION_IDS[@]}"; do
  if [[ ! -f "${VARFILES[$i]}" ]]; then
    echo "Missing var file: ${VARFILES[$i]}" >&2
    exit 1
  fi
done

require_cmd docker
require_cmd git
require_cmd shasum
require_cmd terraform

cd "$ROOT"
if [[ "$DRY_RUN" != "true" ]]; then
  require_cmd gh
  gh auth status >/dev/null
  require_clean_tree
  require_branch_synced
  echo "==> Fetching Caddy release tags"
  git fetch origin --tags --prune --quiet
fi

RELEASE_VERSION="$(next_patch_version)"
CADDY_TAG="${TAG_PREFIX}${RELEASE_VERSION}"

if [[ "$DRY_RUN" != "true" ]]; then
  if git rev-parse -q --verify "refs/tags/${CADDY_TAG}" >/dev/null; then
    echo "Local tag ${CADDY_TAG} already exists. Use a new version." >&2
    exit 1
  fi

  if git ls-remote --exit-code --tags origin "refs/tags/${CADDY_TAG}" >/dev/null 2>&1; then
    echo "Remote tag ${CADDY_TAG} already exists. Use a new version." >&2
    exit 1
  fi

  if gh release view "$CADDY_TAG" >/dev/null 2>&1; then
    echo "GitHub release ${CADDY_TAG} already exists. Use a new version." >&2
    exit 1
  fi
elif git rev-parse -q --verify "refs/tags/${CADDY_TAG}" >/dev/null; then
  echo "Tag ${CADDY_TAG} already exists. Pick another version." >&2
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  BUILD_DIR="$CADDY_DIR/build/${CADDY_TAG}-dry-run-$(date +%Y%m%d%H%M%S)"
else
  BUILD_DIR="$CADDY_DIR/build/${CADDY_TAG}"
fi

if [[ -e "$BUILD_DIR" ]]; then
  echo "Build directory already exists: $BUILD_DIR" >&2
  echo "Move it aside or choose another version." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"
ARTIFACT="$BUILD_DIR/$ASSET_NAME"

echo "==> Building ${ASSET_NAME} for linux/arm64 (${CADDY_TAG})"
docker buildx build \
  --platform linux/arm64 \
  --target verify \
  --build-arg "CADDY_VERSION=$CADDY_VERSION" \
  --build-arg "CADDY_RATE_LIMIT_MODULE=$CADDY_RATE_LIMIT_MODULE" \
  "$CADDY_DIR"

docker buildx build \
  --platform linux/arm64 \
  --target artifact \
  --output "type=local,dest=$BUILD_DIR" \
  --build-arg "CADDY_VERSION=$CADDY_VERSION" \
  --build-arg "CADDY_RATE_LIMIT_MODULE=$CADDY_RATE_LIMIT_MODULE" \
  "$CADDY_DIR"

chmod 755 "$ARTIFACT"
if command -v file >/dev/null 2>&1; then
  file "$ARTIFACT"
fi

CADDY_SHA256="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
echo "==> ${ASSET_NAME} sha256: ${CADDY_SHA256}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "==> Dry run complete; no commit, tag, release, or tfvars updates were made."
  for i in "${!REGION_IDS[@]}"; do
    echo "Would set ${REGION_IDS[$i]}: caddy_binary_tag = \"${CADDY_TAG}\""
    echo "Would set ${REGION_IDS[$i]}: caddy_binary_sha256 = \"${CADDY_SHA256}\""
  done
  exit 0
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
CURRENT_FILE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
validate_version "$CURRENT_FILE_VERSION"

if [[ "$CURRENT_FILE_VERSION" == "$RELEASE_VERSION" ]]; then
  echo "==> Infrastructure/OCI/caddy/VERSION already at ${RELEASE_VERSION}"
else
  echo "==> Bumping Infrastructure/OCI/caddy/VERSION to ${RELEASE_VERSION}"
  printf '%s\n' "$RELEASE_VERSION" > "$VERSION_FILE"

  echo "==> Committing and pushing Caddy v${RELEASE_VERSION} on ${BRANCH}"
  git add "$VERSION_FILE"
  git commit -m "Release Caddy v${RELEASE_VERSION}"
  git push origin "$BRANCH"
fi

RELEASE_NOTES="CloudGateway Caddy ${RELEASE_VERSION}

Built from ${CADDY_VERSION} with ${CADDY_RATE_LIMIT_MODULE}.

Asset: ${ASSET_NAME}
SHA-256: ${CADDY_SHA256}"

echo "==> Creating GitHub release ${CADDY_TAG}"
gh release create "$CADDY_TAG" "$ARTIFACT" \
  --target "$BRANCH" \
  --title "Caddy v${RELEASE_VERSION}" \
  --notes "$RELEASE_NOTES"

update_region_tfvars
echo "==> Caddy release ${CADDY_TAG} complete"
