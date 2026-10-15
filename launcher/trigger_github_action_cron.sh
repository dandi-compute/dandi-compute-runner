#!/usr/bin/env bash
#
# Start a GitHub Actions workflow only when a check on this login node says there is work for it.
#
# Usage: trigger_github_action_cron.sh NAME WORKFLOW_FILE -- CHECK_COMMAND [ARGS...]
#
#   NAME            a short name for logs and the lock file (e.g. dispatch, create)
#   WORKFLOW_FILE   the workflow to start through workflow_dispatch (e.g. process-queue.yml)
#   CHECK_COMMAND   run in the dandi+compute environment; exit 0 means there is work, so the
#                   workflow is started, and exit 1 means there is none, so nothing is sent to
#                   GitHub. Any other exit status is a failure of the check and fails this run.
#
# Run from cron through small wrappers (dispatch_github_action_cron.sh,
# create_github_action_cron.sh), so the GitHub-side workflows need no schedule of their own and
# the runner only runs them when they have something to do.
#
# NOTE: keep the crontab line free of '%' characters. cron turns an unescaped
# '%' into a newline and sends the rest to stdin, which silently breaks the
# command. This script does its own timestamping, so the crontab needs no awk
# pipe.

set -euo pipefail

if [ "$#" -lt 4 ] || [ "$3" != "--" ]; then
  echo "usage: trigger_github_action_cron.sh NAME WORKFLOW_FILE -- CHECK_COMMAND [ARGS...]" >&2
  exit 2
fi
NAME="$1"
WORKFLOW_FILE="$2"
shift 3

# --- timestamp every line ----------------------------------------------------
# Prefix ALL stdout/stderr (including Python/lmod warnings that bypass log())
# with a wall-clock timestamp. Done here, inside the script, so the crontab
# never needs the '%'-laden awk pipe.
exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%F %T')" "$line"; done) 2>&1

# --- logging -----------------------------------------------------------------
log() { printf '[%s] %s\n' "$NAME" "$*"; }
die() { log "ERROR: $*"; exit 1; }

log "=== ${NAME} run starting (pid $$) ==="

# --- single instance ---------------------------------------------------------
# Stops overlapping runs from stacking up if a previous run is wedged. A wedged
# run keeps the lock, so `ps`/the log shows exactly one stuck pid to inspect.
LOCK_FILE="/orcd/data/dandi/001/dandi-compute/flocks/${NAME}_github_action_cron.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another ${NAME} run holds $LOCK_FILE; exiting."
  exit 0
fi

# --- environment -------------------------------------------------------------
log "Sourcing $HOME/.dandi_env"
# shellcheck disable=SC1091
source "$HOME/.dandi_env"

# `set -u` does NOT catch a set-but-empty variable, the classic "works by hand,
# silently no-ops from cron" failure. Fail loudly instead of sending an empty
# Bearer token later.
: "${GH_TOKEN:?GH_TOKEN is empty or unset after sourcing .dandi_env}"

# --- maintenance window check ------------------------------------------------
maintenance_threshold=5
maintenance_held=$(
  squeue --me --noheader --states=PENDING --format='%100R' \
    | grep -c 'Reserved for maintenance' || true
)
log "Maintenance-held pending jobs: ${maintenance_held} (threshold ${maintenance_threshold})"
if (( maintenance_held >= maintenance_threshold )); then
  log "At/over maintenance threshold; skipping ${NAME}."
  exit 0
fi

# --- module / conda environment ----------------------------------------------
# lmod's init references $FPATH unguarded, which trips `set -u`. Relax nounset
# only around the module machinery so a stray unbound variable can't abort us.
log "Loading modules and activating conda environment"
set +u
source /etc/profile.d/modules.sh
module load miniforge
conda activate /orcd/data/dandi/001/environments/name-dandi+compute_env
set -u

# --- connectivity preflight --------------------------------------------------
# Bounded check so a cron environment that cannot reach GitHub (missing proxy,
# different resolver, etc.) reports a clear failure instead of the dispatch
# hanging with no output.
log "Checking GitHub API reachability"
gh_ping=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  https://api.github.com 2>&1) \
  || die "Cannot reach api.github.com from this environment: ${gh_ping}"
log "api.github.com reachable (HTTP ${gh_ping})"

# --- work check --------------------------------------------------------------
log "Checking for work: $*"
check_status=0
"$@" || check_status=$?
case "$check_status" in
  0) log "Work found; starting ${WORKFLOW_FILE}" ;;
  1) log "No work; not starting ${WORKFLOW_FILE}."; exit 0 ;;
  *) die "The check failed (exit ${check_status}); not starting ${WORKFLOW_FILE}." ;;
esac

# --- dispatch ----------------------------------------------------------------
# Bounded, retried, and always reports its HTTP status. A successful
# workflow_dispatch returns 204; anything else dumps the response body so the
# reason (401/403 token, 404/422 disabled/renamed workflow, ...) is logged.
# The token goes in through a header file rather than the command line, which
# anyone on the node can read, and which duct records (see launcher/record.sh).
response_body="$(mktemp)"
trap 'rm -f "$response_body"' EXIT

http_code=$(
  curl -sS --max-time 30 --retry 3 --retry-connrefused \
    -o "$response_body" -w '%{http_code}' \
    -X POST \
    -H @<(printf 'Authorization: Bearer %s\n' "$GH_TOKEN") \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/dandi-compute/dandi-compute-runner/actions/workflows/${WORKFLOW_FILE}/dispatches" \
    -d '{"ref":"main"}'
) || die "curl failed to complete the dispatch request"

if [[ "$http_code" == "204" ]]; then
  log "workflow_dispatch accepted (HTTP 204); run should appear in Actions."
else
  log "workflow_dispatch FAILED (HTTP ${http_code}); response body:"
  cat "$response_body"
  exit 1
fi

log "=== ${NAME} run complete ==="
