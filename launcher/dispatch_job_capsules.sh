#!/usr/bin/env bash
#
# Dispatch the "Dispatch job capsules" GitHub Action (process-queue.yml).
#
# Called by launch_submitter.sh once its runner is listening, so every submitter job that
# starts dispatches exactly once. The run it leaves in the Actions tab is the record that the
# cluster came up and tried to dispatch that day, whether or not anything was waiting.

set -euo pipefail

# --- timestamp every line ----------------------------------------------------
exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%F %T')" "$line"; done) 2>&1

# --- logging -----------------------------------------------------------------
log() { printf '[dispatch] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

log "=== dispatch starting (pid $$) ==="

# --- environment -------------------------------------------------------------
log "Sourcing $HOME/.dandi_env"
# shellcheck disable=SC1091
source "$HOME/.dandi_env"

# `set -u` does NOT catch a set-but-empty variable, the classic "works by hand,
# silently no-ops from cron" failure. Fail loudly instead of sending an empty
# Bearer token later.
: "${GH_TOKEN:?GH_TOKEN is empty or unset after sourcing .dandi_env}"

# --- connectivity preflight --------------------------------------------------
# Bounded check so an environment that cannot reach GitHub (missing proxy,
# different resolver, etc.) reports a clear failure instead of the dispatch
# hanging with no output.
log "Checking GitHub API reachability"
gh_ping=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  https://api.github.com 2>&1) \
  || die "Cannot reach api.github.com from this environment: ${gh_ping}"
log "api.github.com reachable (HTTP ${gh_ping})"

# --- dispatch ----------------------------------------------------------------
# Bounded, retried, and always reports its HTTP status. A successful
# workflow_dispatch returns 204; anything else dumps the response body so the
# reason (401/403 token, 404/422 disabled/renamed workflow, ...) is logged.
response_body="$(mktemp)"
trap 'rm -f "$response_body"' EXIT

http_code=$(
  curl -sS --max-time 30 --retry 3 --retry-connrefused \
    -o "$response_body" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/dandi-compute/dandi-compute-runner/actions/workflows/process-queue.yml/dispatches \
    -d '{"ref":"main"}'
) || die "curl failed to complete the dispatch request"

if [[ "$http_code" == "204" ]]; then
  log "workflow_dispatch accepted (HTTP 204); run should appear in Actions."
else
  log "workflow_dispatch FAILED (HTTP ${http_code}); response body:"
  cat "$response_body"
  exit 1
fi

log "=== dispatch complete ==="
