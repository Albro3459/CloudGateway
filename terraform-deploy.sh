#!/usr/bin/env bash

# Deploy/manage one shared regional WireGuard server.
#
# Usage:
#   ./terraform-deploy.sh <region> [plan|apply|destroy]
#
# <region> accepts a short name (chicago, sanjose) which expands to us-<region>-1,
# or a full region id (us-chicago-1) used as-is.
#
# Default action is apply. apply/destroy always show the plan and require typing "yes".
#
# Examples:
#   ./terraform-deploy.sh chicago            # apply us-chicago-1 (shows plan, asks yes)
#   ./terraform-deploy.sh sanjose plan       # plan only, no prompt, no changes
#   ./terraform-deploy.sh chicago destroy    # tear Chicago down (asks yes)
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
ACTION="${2:-apply}"
TFDIR="$(cd "$(dirname "$0")/OCI/terraform" && pwd)"

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

cd "$TFDIR"
terraform init -input=false >/dev/null
terraform workspace select "$REGION_ID" 2>/dev/null || terraform workspace new "$REGION_ID"
echo "==> workspace: $(terraform workspace show)  var-file: ${REGION_ID}.terraform.tfvars"

case "$ACTION" in
  plan)    terraform plan -input=false -var-file="$VARFILE" ;;
  # apply/destroy keep the interactive plan + "yes" approval prompt on purpose.
  apply)   terraform apply   -var-file="$VARFILE" ;;
  destroy) terraform destroy -var-file="$VARFILE" ;;
  *) echo "unknown action: $ACTION (expected plan|apply|destroy)" >&2; exit 2 ;;
esac
