#!/usr/bin/env bash
# Bootstrap script: add automation stubs to all Itqan-community repos via PRs
# Run from the root of the Itqan-community/.github repo after pushing central workflows.
#
# What it does:
#   - Creates branch automation/add-workflows in each repo
#   - Commits stub files + release-drafter config to that branch
#   - Opens a PR for review (does not merge)
#   - Skips repos that already have the stub files
#   - Skips archived repos and the .github repo itself
#
# Usage: bash bootstrap.sh [--dry-run]
#
# Requirements: gh CLI authenticated as abubakr-itqan (needs workflow scope)

set -euo pipefail

ORG="Itqan-community"
BRANCH="automation/add-workflows"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

STUB_DIR="$(cd "$(dirname "$0")/stubs" && pwd)"
RELEASE_DRAFTER_CONFIG="$(cd "$(dirname "$0")/.github" && pwd)/release-drafter.yml"

SKIP_REPOS=(".github")

log()  { echo "[bootstrap] $*"; }
skip() { echo "[skip]      $*"; }
dry()  { echo "[dry-run]   would $*"; }

create_environment() {
  local repo="$1" env="$2"
  gh api "repos/${ORG}/${repo}/environments/${env}" \
    --method PUT \
    --input /dev/null \
    --silent
}

default_branch() {
  gh api "repos/${ORG}/$1" --jq '.default_branch'
}

branch_exists() {
  gh api "repos/${ORG}/$1/branches/$2" --silent 2>/dev/null
}

create_branch() {
  local repo="$1" base_sha
  base_sha=$(gh api "repos/${ORG}/${repo}/git/refs/heads/$(default_branch "$repo")" --jq '.object.sha')
  gh api "repos/${ORG}/${repo}/git/refs" \
    --method POST \
    -f ref="refs/heads/${BRANCH}" \
    -f sha="$base_sha" \
    --silent
}

push_file() {
  local repo="$1" dest_path="$2" src_file="$3" commit_msg="$4"
  local content
  content=$(base64 < "$src_file" | tr -d '\n')

  gh api "repos/${ORG}/${repo}/contents/${dest_path}" \
    --method PUT \
    -f message="$commit_msg" \
    -f content="$content" \
    -f branch="${BRANCH}" \
    --silent
}

log "Fetching repo list for ${ORG}..."
repos=$(gh repo list "$ORG" --limit 100 --json name,isArchived \
  | jq -r '.[] | select(.isArchived == false) | .name')

for repo in $repos; do
  skip_this=false
  for s in "${SKIP_REPOS[@]}"; do
    [[ "$repo" == "$s" ]] && skip_this=true && break
  done
  $skip_this && skip "$repo (excluded)" && continue

  # Determine which stubs are missing
  missing_stubs=()
  for stub_file in "$STUB_DIR"/*.yml; do
    filename=$(basename "$stub_file")
    if ! gh api "repos/${ORG}/${repo}/contents/.github/workflows/${filename}" --silent 2>/dev/null; then
      missing_stubs+=("$stub_file")
    fi
  done

  if [[ ${#missing_stubs[@]} -eq 0 ]]; then
    skip "$repo (all stubs present)"
    continue
  fi

  log "Processing ${repo} (missing: $(printf '%s ' "${missing_stubs[@]}" | xargs -n1 basename | tr '\n' ' '))..."

  if $DRY_RUN; then
    dry "push ${#missing_stubs[@]} stub(s) to ${repo}"
    continue
  fi

  # Create branch (skip if it already exists)
  if ! branch_exists "$repo" "$BRANCH"; then
    create_branch "$repo"
  fi

  for stub in "${missing_stubs[@]}"; do
    filename=$(basename "$stub")
    push_file "$repo" ".github/workflows/${filename}" "$stub" \
      "chore: add ${filename%.*} automation stub"
    log "  added .github/workflows/${filename}"
  done

  push_file "$repo" ".github/release-drafter.yml" "$RELEASE_DRAFTER_CONFIG" \
    "chore: add release-drafter config"
  log "  added .github/release-drafter.yml"

  # Create GitHub Environments
  for env in staging prod; do
    create_environment "$repo" "$env"
    log "  environment '${env}' created"
  done

  # Open PR
  pr_url=$(gh pr create \
    --repo "${ORG}/${repo}" \
    --head "${BRANCH}" \
    --base "$(default_branch "$repo")" \
    --title "chore: add automation workflows" \
    --body "Adds centralized automation workflow stubs from \`Itqan-community/.github\`.

## What's included
- \`slack-notifications.yml\` — PR/issue/push events → Slack
- \`branch-naming.yml\` — enforces feature/\*, hotfix/\*, community/\*
- \`community-detection.yml\` — labels and notifies external contributors
- \`stale.yml\` — 14d stale label, 21d auto-close
- \`release-drafter.yml\` — auto-drafts release notes grouped by feat/fix/chore
- \`notion-sync.yml\` — GitHub issues → Notion tasks (Phase 2, needs NOTION_API_KEY secret)
- \`hub-compliance.yml\` — verifies all required stubs present on every PR (org compliance gate)
- \`release-drafter.yml\` config — release note template

All workflow logic lives in [\`Itqan-community/.github\`](https://github.com/Itqan-community/.github). These files are thin stubs that call into the central workflows.

## Secrets required
\`SLACK_WEBHOOK_ENGINEERING_ALERTS\`, \`SLACK_WEBHOOK_RELEASES\`, \`SLACK_WEBHOOK_COMMUNITY_UPDATES\`, \`SLACK_WEBHOOK_INCIDENTS\` — set at repo level.
\`NOTION_API_KEY\`, \`NOTION_TASKS_DB_ID\` — set these before merging if you want Notion sync active.
\`HEALTH_CHECK_URL\` — optional. Set to your Railway service URL (e.g. \`https://your-app.railway.app/health\`) to enable post-deploy health checks.

## GitHub Environments
\`staging\` and \`prod\` environments have been created on this repo. Override any secret per-environment when values differ.")
  log "PR opened: $pr_url"

done

log "Done."
