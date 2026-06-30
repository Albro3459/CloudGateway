#!/usr/bin/env bash

# Deploy/manage shared regional WireGuard servers.
#
# Usage:
#   ./scripts/terraform.sh <region> [<region> ...] [plan|apply|destroy]
#
# <region> accepts a short name (chicago, sanjose) which expands to us-<region>-1,
# or a full region id (us-chicago-1) used as-is.
#
# Default action is apply. plan does not cut tags or change infrastructure.
# apply cuts one deploy tag, writes that same tag to every listed region tfvars,
# saves each region's final plan, asks once on bare invocation, then applies each
# saved plan in sequence. destroy uses Terraform's native per-region confirmation.
#
# Examples:
#   ./scripts/terraform.sh chicago                    # apply us-chicago-1 (shows plan, asks yes)
#   ./scripts/terraform.sh chicago sanjose            # apply both regions with one deploy tag
#   ./scripts/terraform.sh chicago sanjose plan       # plan both regions only, no prompt
#   ./scripts/terraform.sh chicago destroy            # tear Chicago down (asks yes)
#
# Each region gets:
#   - its own var file:  Infrastructure/OCI/terraform/<region-id>.terraform.tfvars (gitignored)
#   - its own workspace: isolated state so regions never clobber each other
#   - its own OCI auth:  the oci_config_profile set inside that var file
#
# Without this, a bare `terraform apply` auto-loads terraform.tfvars and shares one
# state file, so deploying a second region would plan to destroy the first.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TFDIR="$ROOT/Infrastructure/OCI/terraform"
API_VERSION_FILE="$ROOT/Backend/API/src/version.py"
PREFLIGHT="$ROOT/scripts/terraform-preflight.py"
RAW_ACTION=""      # empty when no action is given (bare `./scripts/terraform.sh <region>`)
ACTION="apply"
REGIONS=("$@")
REGION_IDS=()
VARFILES=()
DEPLOY_VERSION=""
DEPLOY_TAG=""
DEPLOY_PREVIOUS_TAG=""
APPLY_PLANFILES=()
TEMPFILES=()

usage() {
  echo "usage: $0 <region> [<region> ...] [plan|apply|destroy]   (region: chicago | sanjose | us-<x>-1)" >&2
}

if [[ ${#REGIONS[@]} -eq 0 ]]; then
  usage
  exit 2
fi

last_index=$((${#REGIONS[@]} - 1))
case "${REGIONS[$last_index]}" in
  plan|apply|destroy)
    RAW_ACTION="${REGIONS[$last_index]}"
    ACTION="$RAW_ACTION"
    unset "REGIONS[$last_index]"
    ;;
esac

if [[ ${#REGIONS[@]} -eq 0 ]]; then
  usage
  exit 2
fi

for region in "${REGIONS[@]}"; do
  # Expand a short name to a full region id; pass a full us-<x>-<n> id through unchanged.
  case "$region" in
    us-*-*) region_id="$region" ;;
    *)      region_id="us-${region}-1" ;;
  esac

  REGION_IDS+=("$region_id")
  VARFILES+=("$TFDIR/${region_id}.terraform.tfvars")
done

varfile_error=0
for i in "${!REGION_IDS[@]}"; do
  if [[ ! -f "${VARFILES[$i]}" ]]; then
    echo "Missing var file: ${VARFILES[$i]}" >&2
    echo "Copy Infrastructure/OCI/terraform/terraform.tfvars.example to ${REGION_IDS[$i]}.terraform.tfvars and fill it in." >&2
    varfile_error=1
  elif ! grep -q '^[[:space:]]*source_ref[[:space:]]*=' "${VARFILES[$i]}"; then
    echo "Missing source_ref in ${VARFILES[$i]}" >&2
    echo "Add source_ref to ${REGION_IDS[$i]}.terraform.tfvars before deploying." >&2
    varfile_error=1
  fi
done

[[ "$varfile_error" -eq 0 ]] || exit 1

cleanup_apply_planfiles() {
  local tempfile

  for tempfile in "${TEMPFILES[@]}"; do
    [[ -n "$tempfile" ]] && rm -f "$tempfile"
  done
}

format_varfile() {
  local varfile="$1"

  terraform -chdir="$TFDIR" fmt "$(basename "$varfile")" >/dev/null
}

require_clean_tree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean. Commit or stash everything before deploying:" >&2
    git status --short >&2
    exit 1
  fi
}

prepare_next_deploy_tag() {
  local latest_tag ver maj min pat

  echo "==> Fetching tags from origin"
  git fetch origin --tags --prune --quiet

  latest_tag="$(git tag -l 'deploy-v*' | sort -V | tail -n1)"
  DEPLOY_PREVIOUS_TAG="$latest_tag"
  if [[ -z "$latest_tag" ]]; then
    DEPLOY_VERSION="1.0.0"
  else
    ver="${latest_tag#deploy-v}"
    IFS=. read -r maj min pat <<< "$ver"
    DEPLOY_VERSION="${maj}.${min}.$((pat + 1))"
  fi
  DEPLOY_TAG="deploy-v${DEPLOY_VERSION}"

  if git rev-parse -q --verify "refs/tags/${DEPLOY_TAG}" >/dev/null; then
    echo "Tag ${DEPLOY_TAG} already exists. Resolve it and re-run." >&2
    exit 1
  fi
}

# Cut a fresh deploy version, commit it to the API, and tag it. Runs once before
# apply so every selected region boots from the same pushed tag and API version.py
# matches the deployed ref.
create_deploy_tag() {
  local confirm branch latest_tag

  if [[ "${1:-}" != "--confirmed" ]]; then
    read -r -p "Are you fully committed and ready to make a terraform + API deployment? Type 'yes' to continue: " confirm
    [[ "$confirm" == "yes" ]] || { echo "Aborted." >&2; exit 1; }
  fi

  require_clean_tree
  echo "==> Verifying deploy tags have not changed"
  git fetch origin --tags --prune --quiet
  latest_tag="$(git tag -l 'deploy-v*' | sort -V | tail -n1)"
  if [[ "$latest_tag" != "$DEPLOY_PREVIOUS_TAG" ]]; then
    echo "Latest deploy tag changed from ${DEPLOY_PREVIOUS_TAG:-none} to ${latest_tag:-none}. Re-run to review fresh plans." >&2
    exit 1
  fi

  if git rev-parse -q --verify "refs/tags/${DEPLOY_TAG}" >/dev/null; then
    echo "Tag ${DEPLOY_TAG} already exists. Resolve it and re-run." >&2
    exit 1
  fi

  branch="$(git rev-parse --abbrev-ref HEAD)"
  echo "==> Bumping Backend/API/src/version.py to ${DEPLOY_VERSION}"
  printf '__version__ = "%s"\n' "$DEPLOY_VERSION" > "$API_VERSION_FILE"

  echo "==> Committing and pushing Deploy v${DEPLOY_VERSION} on ${branch}"
  git add "$API_VERSION_FILE"
  git commit -m "Deploy v${DEPLOY_VERSION}"
  git push origin "$branch"

  echo "==> Tagging ${DEPLOY_TAG} and pushing it"
  git tag "$DEPLOY_TAG"
  git push origin "$DEPLOY_TAG"
}

set_source_ref() {
  local region_id="$1" varfile="$2" tag="$3" tmp

  if ! grep -q '^[[:space:]]*source_ref[[:space:]]*=' "$varfile"; then
    echo "Missing source_ref in ${varfile}" >&2
    exit 1
  fi

  echo "==> Setting source_ref = \"${tag}\" in ${region_id}.terraform.tfvars"
  tmp="$(mktemp)"
  sed "s|^[[:space:]]*source_ref[[:space:]]*=.*|source_ref  = \"${tag}\"|" "$varfile" > "$tmp"
  mv "$tmp" "$varfile"
  format_varfile "$varfile"
}

select_region_workspace() {
  local region_id="$1" varfile="$2"

  terraform workspace select "$region_id" 2>/dev/null || terraform workspace new "$region_id"
  echo "==> workspace: $(terraform workspace show)  var-file: $(basename "$varfile")"
}

preflight_region() {
  local region_id="$1" varfile="$2"

  select_region_workspace "$region_id" "$varfile"
  python3 "$PREFLIGHT" --region-id "$region_id" --var-file "$varfile"
}

plan_region() {
  local region_id="$1" varfile="$2" planfile planjson

  select_region_workspace "$region_id" "$varfile"
  planfile="$(mktemp "${TMPDIR:-/tmp}/cloudgateway-terraform-plan.XXXXXX")"
  planjson="$(mktemp "${TMPDIR:-/tmp}/cloudgateway-terraform-plan-json.XXXXXX")"
  TEMPFILES+=("$planfile" "$planjson")
  terraform plan -input=false -var-file="$varfile" -out="$planfile" >/dev/null
  terraform show -json "$planfile" > "$planjson"
  python3 "$PREFLIGHT" --region-id "$region_id" --var-file "$varfile" --plan-json "$planjson"
  terraform show -no-color "$planfile"
}

save_apply_plan() {
  local region_id="$1" varfile="$2" tag="$3" planfile="$4" planjson

  select_region_workspace "$region_id" "$varfile"
  terraform plan -input=false -var-file="$varfile" -var="source_ref=${tag}" -out="$planfile"
  planjson="$(mktemp "${TMPDIR:-/tmp}/cloudgateway-terraform-plan-json.XXXXXX")"
  TEMPFILES+=("$planjson")
  terraform show -json "$planfile" > "$planjson"
  python3 "$PREFLIGHT" --region-id "$region_id" --var-file "$varfile" --plan-json "$planjson"
}

cd "$TFDIR"
terraform init -input=false >/dev/null

case "$ACTION" in
  plan)
    trap cleanup_apply_planfiles EXIT
    for i in "${!REGION_IDS[@]}"; do
      plan_region "${REGION_IDS[$i]}" "${VARFILES[$i]}"
    done
    ;;
  # apply shows final plans once, cuts and pushes one fresh deploy tag, points
  # every requested region at it, then applies each region without extra prompts.
  apply)
    require_clean_tree
    prepare_next_deploy_tag
    trap cleanup_apply_planfiles EXIT

    for i in "${!REGION_IDS[@]}"; do
      planfile="$(mktemp "${TMPDIR:-/tmp}/cloudgateway-terraform-plan.XXXXXX")"
      APPLY_PLANFILES+=("$planfile")
      TEMPFILES+=("$planfile")
      save_apply_plan "${REGION_IDS[$i]}" "${VARFILES[$i]}" "$DEPLOY_TAG" "$planfile"
    done

    # Bare `./scripts/terraform.sh <region> [<region> ...]` shows final plans and confirms
    # intent before touching tags. Explicit `... apply` still uses create_deploy_tag's
    # readiness prompt, matching the old explicit-apply gate.
    if [[ -z "$RAW_ACTION" ]]; then
      read -r -p "Proceed with deploy tag ${DEPLOY_TAG}, source_ref updates, and apply for ${#REGION_IDS[@]} region(s)? Type 'yes' to continue: " confirm
      [[ "$confirm" == "yes" ]] || { echo "Aborted." >&2; exit 1; }
      create_deploy_tag --confirmed
    else
      create_deploy_tag
    fi

    for i in "${!REGION_IDS[@]}"; do
      set_source_ref "${REGION_IDS[$i]}" "${VARFILES[$i]}" "$DEPLOY_TAG"
    done

    for i in "${!REGION_IDS[@]}"; do
      select_region_workspace "${REGION_IDS[$i]}" "${VARFILES[$i]}"
      terraform apply -input=false "${APPLY_PLANFILES[$i]}"
    done
    ;;
  destroy)
    for i in "${!REGION_IDS[@]}"; do
      preflight_region "${REGION_IDS[$i]}" "${VARFILES[$i]}"
    done

    for i in "${!REGION_IDS[@]}"; do
      select_region_workspace "${REGION_IDS[$i]}" "${VARFILES[$i]}"
      terraform destroy -var-file="${VARFILES[$i]}"
    done
    ;;
  *)
    echo "unknown action: $ACTION (expected plan|apply|destroy)" >&2
    exit 2
    ;;
esac
