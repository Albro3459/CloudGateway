#!/usr/bin/env bash

# Deploy/manage one shared regional WireGuard server.
#
# Usage:
#   ./terraform.sh <region> [plan|apply|destroy]
#
# <region> accepts a short name (chicago, sanjose) which expands to us-<region>-1,
# or a full region id (us-chicago-1) used as-is.
#
# Default action is apply. apply/destroy always show the plan and require typing "yes".
#
# Examples:
#   ./terraform.sh chicago            # apply us-chicago-1 (shows plan, asks yes)
#   ./terraform.sh sanjose plan       # plan only, no prompt, no changes
#   ./terraform.sh chicago destroy    # tear Chicago down (asks yes)
#
# Each region gets:
#   - its own var file:  OCI/terraform/<region-id>.terraform.tfvars (gitignored)
#   - its own workspace: isolated state so regions never clobber each other
#   - its own OCI auth:  the oci_config_profile set inside that var file
#
# Without this, a bare `terraform apply` auto-loads terraform.tfvars and shares one
# state file, so deploying a second region would plan to destroy the first.

set -euo pipefail

ARG="${1:-}"
RAW_ACTION="${2:-}"      # empty when no action is given (bare `./terraform.sh <region>`)
ACTION="${RAW_ACTION:-apply}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
TFDIR="$ROOT/OCI/terraform"
API_VERSION_FILE="$ROOT/API/src/version.py"

if [[ -z "$ARG" ]]; then
  echo "usage: $0 <region> [plan|apply|destroy]   (region: chicago | sanjose | us-<x>-1)" >&2
  exit 2
fi

# Expand a short name to a full region id; pass a full us-<x>-<n> id through unchanged.
case "$ARG" in
  us-*-*) REGION_ID="$ARG" ;;
  *)      REGION_ID="us-${ARG}-1" ;;
esac

VARFILE="$TFDIR/${REGION_ID}.terraform.tfvars"
if [[ ! -f "$VARFILE" ]]; then
  echo "Missing var file: $VARFILE" >&2
  echo "Copy OCI/terraform/terraform.tfvars.example to ${REGION_ID}.terraform.tfvars and fill it in." >&2
  exit 1
fi

# Cut a fresh deploy version, commit it to the API, tag it, and point this region's
# var file at the tag. Runs before apply so the host boots from a tag that exists on
# origin and the API version.py always matches the deployed tag. Steps:
#   1. confirm the user is committed and ready for a terraform + API deployment
#   2. require a fully clean working tree (so the only commit is the version bump)
#   3. find the latest deploy-vX.Y.Z tag and bump the patch
#   4. write the new version to API/src/version.py, commit "Deploy v<ver>", push it
#   5. tag that commit and push the tag
#   6. set source_ref in this region's tfvars to the new tag (overwrites any value,
#      even a large jump from what is there now)
prepare_deploy_ref() {
  local confirm branch latest_tag ver maj min pat new_ver new_tag tmp

  read -r -p "Are you fully committed and ready to make a terraform + API deployment? Type 'yes' to continue: " confirm
  [[ "$confirm" == "yes" ]] || { echo "Aborted." >&2; exit 1; }

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean. Commit or stash everything before deploying:" >&2
    git status --short >&2
    exit 1
  fi

  branch="$(git rev-parse --abbrev-ref HEAD)"
  echo "==> Fetching tags from origin"
  git fetch origin --tags --prune --quiet

  latest_tag="$(git tag -l 'deploy-v*' | sort -V | tail -n1)"
  if [[ -z "$latest_tag" ]]; then
    new_ver="1.0.0"
  else
    ver="${latest_tag#deploy-v}"
    IFS=. read -r maj min pat <<< "$ver"
    new_ver="${maj}.${min}.$((pat + 1))"
  fi
  new_tag="deploy-v${new_ver}"

  if git rev-parse -q --verify "refs/tags/${new_tag}" >/dev/null; then
    echo "Tag ${new_tag} already exists. Resolve it and re-run." >&2
    exit 1
  fi

  echo "==> Bumping API/src/version.py to ${new_ver} (was ${latest_tag:-none})"
  printf '__version__ = "%s"\n' "$new_ver" > "$API_VERSION_FILE"

  echo "==> Committing and pushing Deploy v${new_ver} on ${branch}"
  git add "$API_VERSION_FILE"
  git commit -m "Deploy v${new_ver}"
  git push origin "$branch"

  echo "==> Tagging ${new_tag} and pushing it"
  git tag "$new_tag"
  git push origin "$new_tag"

  echo "==> Setting source_ref = \"${new_tag}\" in ${REGION_ID}.terraform.tfvars"
  tmp="$(mktemp)"
  sed "s|^source_ref .*|source_ref  = \"${new_tag}\"|" "$VARFILE" > "$tmp"
  mv "$tmp" "$VARFILE"
}

cd "$TFDIR"
terraform init -input=false >/dev/null
terraform workspace select "$REGION_ID" 2>/dev/null || terraform workspace new "$REGION_ID"
echo "==> workspace: $(terraform workspace show)  var-file: ${REGION_ID}.terraform.tfvars"

case "$ACTION" in
  plan)    terraform plan -input=false -var-file="$VARFILE" ;;
  # apply/destroy keep the interactive plan + "yes" approval prompt on purpose.
  # apply cuts and pushes a fresh deploy tag, then points this region at it.
  apply)
    # Bare `./terraform.sh <region>` shows the plan first and confirms intent to
    # deploy before touching tags. Explicit `... apply` skips straight to the steps.
    if [[ -z "$RAW_ACTION" ]]; then
      terraform plan -input=false -var-file="$VARFILE"
      read -r -p "Proceed with the deploy steps (tag, push, apply)? Type 'yes' to continue: " confirm
      [[ "$confirm" == "yes" ]] || { echo "Aborted." >&2; exit 1; }
    fi
    prepare_deploy_ref
    terraform apply -var-file="$VARFILE"
    ;;
  destroy) terraform destroy -var-file="$VARFILE" ;;
  *) echo "unknown action: $ACTION (expected plan|apply|destroy)" >&2; exit 2 ;;
esac
