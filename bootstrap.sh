#!/usr/bin/env bash
# Bootstrap script: add automation stubs to all Itqan-community repos
# Run from the root of the Itqan-community/.github repo after pushing central workflows.
#
# What it does:
#   - Adds .github/workflows/stub files to every active, non-.github repo in the org
#   - Adds .github/release-drafter.yml config to each repo (Release Drafter reads from same repo)
#   - Skips repos that already have the file
#   - Skips archived repos and the .github repo itself
#
# Usage: bash bootstrap.sh [--dry-run]
#
# Requirements: gh CLI authenticated as abubakr-itqan (needs workflow scope)

set -euo pipefail

ORG="Itqan-community"
CENTRAL_REF="main"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

STUB_DIR="$(cd "$(dirname "$0")/stubs" && pwd)"
RELEASE_DRAFTER_CONFIG="$(cd "$(dirname "$0")/.github" && pwd)/release-drafter.yml"

SKIP_REPOS=(".github")

log() { echo "[bootstrap] $*"; }
skip() { echo "[skip]      $*"; }
dry() { echo "[dry-run]   would $*"; }

push_file() {
  local repo="$1" dest_path="$2" src_file="$3" commit_msg="$4"

  # Check if file already exists
  if gh api "repos/${ORG}/${repo}/contents/${dest_path}" --silent 2>/dev/null; then
    skip "${repo}/${dest_path} already exists"
    return
  fi

  if $DRY_RUN; then
    dry "add ${dest_path} to ${repo}"
    return
  fi

  local content
  content=$(base64 < "$src_file" | tr -d '\n')

  gh api "repos/${ORG}/${repo}/contents/${dest_path}" \
    --method PUT \
    -f message="$commit_msg" \
    -f content="$content" \
    --silent

  log "added ${dest_path} to ${repo}"
}

log "Fetching repo list for ${ORG}..."
repos=$(gh repo list "$ORG" --limit 100 --json name,isArchived \
  | jq -r '.[] | select(.isArchived == false) | .name')

for repo in $repos; do
  # Skip the central .github repo and any explicitly excluded repos
  skip_this=false
  for s in "${SKIP_REPOS[@]}"; do
    [[ "$repo" == "$s" ]] && skip_this=true && break
  done
  $skip_this && skip "$repo (excluded)" && continue

  log "Processing ${repo}..."

  for stub in "$STUB_DIR"/*.yml; do
    filename=$(basename "$stub")
    push_file "$repo" ".github/workflows/${filename}" "$stub" \
      "chore: add ${filename%.*} automation stub"
  done

  # Release Drafter config must live in each repo (not readable cross-repo)
  push_file "$repo" ".github/release-drafter.yml" "$RELEASE_DRAFTER_CONFIG" \
    "chore: add release-drafter config"

done

log "Done. Remember to:"
log "  1. Add secrets (SLACK_WEBHOOK_*, NOTION_API_KEY, NOTION_TASKS_DB_ID) in org or per-repo settings"
log "  2. Enable Required Workflows at: https://github.com/organizations/${ORG}/settings/actions"
