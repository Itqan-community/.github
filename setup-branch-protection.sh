#!/usr/bin/env bash
# setup-branch-protection.sh
# Adds "Branch Naming Check / check" as a required status check on the default
# branch of every active Itqan-community repo that has the branch-naming stub.
#
# Safe to re-run — skips repos that already have the check configured.
# Usage: bash setup-branch-protection.sh [--dry-run]

set -euo pipefail

ORG="Itqan-community"
REQUIRED_CHECKS=(
  "Branch Naming Check / check"
  "Org Compliance Check / check"
)
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SKIP_REPOS=(".github")

log()  { echo "[branch-protection] $*"; }
skip() { echo "[skip]              $*"; }
dry()  { echo "[dry-run]           would $*"; }

repos=$(gh repo list "$ORG" --limit 100 --json name,isArchived \
  | jq -r '.[] | select(.isArchived == false) | .name')

for repo in $repos; do
  skip_this=false
  for s in "${SKIP_REPOS[@]}"; do
    [[ "$repo" == "$s" ]] && skip_this=true && break
  done
  $skip_this && skip "$repo (excluded)" && continue

  # Get default branch and visibility
  repo_info=$(gh api "repos/${ORG}/${repo}" --jq '{default_branch:.default_branch,private:.private}' 2>/dev/null) || {
    skip "$repo (could not read repo)"
    continue
  }
  default_branch=$(echo "$repo_info" | jq -r '.default_branch')
  is_private=$(echo "$repo_info" | jq -r '.private')

  if [[ "$is_private" == "true" ]]; then
    skip "$repo (private — needs GitHub Team plan for branch protection)"
    continue
  fi

  # Skip if branch-naming stub not present on default branch
  if ! gh api "repos/${ORG}/${repo}/contents/.github/workflows/branch-naming.yml?ref=${default_branch}" --silent 2>/dev/null; then
    skip "$repo (no branch-naming stub on ${default_branch})"
    continue
  fi

  # Read current required status check contexts
  existing_contexts=$(gh api "repos/${ORG}/${repo}/branches/${default_branch}/protection/required_status_checks/contexts" 2>/dev/null || echo "[]")

  # Determine which checks are still missing
  missing_checks=()
  for check in "${REQUIRED_CHECKS[@]}"; do
    if ! echo "$existing_contexts" | jq -e --arg c "$check" 'index($c) != null' > /dev/null 2>&1; then
      missing_checks+=("$check")
    fi
  done

  if [[ ${#missing_checks[@]} -eq 0 ]]; then
    skip "$repo (all required checks already enforced)"
    continue
  fi

  if $DRY_RUN; then
    dry "add required checks to ${repo}/${default_branch}: ${missing_checks[*]}"
    continue
  fi

  # If no protection exists, create minimal protection first
  has_protection=$(gh api "repos/${ORG}/${repo}/branches/${default_branch}" --jq '.protected' 2>/dev/null || echo "false")

  # Build JSON array of ALL required checks (merge existing + missing)
  all_contexts_json=$(echo "$existing_contexts" | jq \
    --argjson new "$(printf '%s\n' "${REQUIRED_CHECKS[@]}" | jq -R . | jq -s .)" \
    '. + $new | unique')

  set_via_put() {
    gh api "repos/${ORG}/${repo}/branches/${default_branch}/protection" \
      --method PUT \
      --input - <<EOF > /dev/null
{
  "required_status_checks": {
    "strict": false,
    "contexts": ${all_contexts_json}
  },
  "enforce_admins": null,
  "required_pull_request_reviews": null,
  "restrictions": null
}
EOF
  }

  if [[ "$has_protection" == "false" ]]; then
    set_via_put
    log "$repo: created branch protection with checks: ${missing_checks[*]}"
  else
    # Try POST to add missing contexts to existing required_status_checks section
    missing_json=$(printf '%s\n' "${missing_checks[@]}" | jq -R . | jq -s .)
    if gh api "repos/${ORG}/${repo}/branches/${default_branch}/protection/required_status_checks/contexts" \
        --method POST --input - <<< "$missing_json" > /dev/null 2>&1; then
      log "$repo: added required checks: ${missing_checks[*]}"
    else
      # No required_status_checks section yet — PUT to create it
      set_via_put
      log "$repo: set required checks: ${missing_checks[*]}"
    fi
  fi
done

log "Done."
