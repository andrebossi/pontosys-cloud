#!/usr/bin/env bash
# The instance's OCI identity, written to /run/instance.env and sourced by the
# agent units. Runs at boot and before every fluent-bit start, so a VM that was
# live-migrated to another fault domain relabels itself.
set -euo pipefail

MD=$(curl -sf --max-time 5 -H "Authorization: Bearer Oracle" \
       http://169.254.169.254/opc/v2/instance/) || MD='{}'

{
  echo "INSTANCE_ID=$(jq -r '.id // "unknown"' <<<"$MD")"
  echo "INSTANCE_NAME=$(jq -r '.displayName // "unknown"' <<<"$MD")"
  echo "SHAPE=$(jq -r '.shape // "unknown"' <<<"$MD")"
  echo "AD=$(jq -r '.availabilityDomain // "unknown"' <<<"$MD")"
  echo "FD=$(jq -r '.faultDomain // "unknown"' <<<"$MD")"
  echo "REGION=$(jq -r '.canonicalRegionName // "unknown"' <<<"$MD")"
  echo "ROLE=$(jq -r '.definedTags.pscloud.role // "unknown"' <<<"$MD")"
  echo "RELEASE=$(jq -r '.metadata.pscloud_release // "unknown"' <<<"$MD")"
} > /run/instance.env

chmod 0644 /run/instance.env
