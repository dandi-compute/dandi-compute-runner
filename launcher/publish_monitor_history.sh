#!/bin/bash
#
# publish_monitor_history.sh - keep a day-by-day summary of the squeue snapshots on the
# monitor-history branch of the global logs repository, for the Status page's history charts.
#
# The snapshots of launcher/monitor.sh live on the monitor/YYYY-MM-DD day branches, which record.sh
# deletes after 30 days, and a day holds nearly 300 of them. launcher/monitor_history.py boils each
# day down to history/YYYY-MM-DD.jsonl, one short JSON line per snapshot: jobs per state, pending
# jobs per reason, memory and CPUs per partition and per capped QOS against the caps, the fair-share
# factor and the priorities of the pending jobs. Those files go on monitor-history, a single branch
# that is never deleted, so the history outlives the day branches and the page reads a day in one
# small request.
#
# Run by the crontab every hour. Today's file and yesterday's are made afresh each time, since their
# branches may still grow; the file of any other day branch on GitHub is made once, when it is
# missing, which also fills in the days from before this script. It records itself under logs/,
# through record.sh like the other launchers. A push that fails is redone from GitHub's branch as
# it then is, and a run that cannot push leaves the next hour to try again.

set -uo pipefail

LOG_REPOSITORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs
RUNNER_REPOSITORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-runner
BRANCH=monitor-history
DIRECTORY=history
# Its own worktree of the shared checkout and its own lock, so it never waits on the deliveries of
# record.sh nor they on it.
WORKTREE="$LOG_REPOSITORY/untracked/worktrees/$BRANCH"
LOCK_FILE="$LOG_REPOSITORY/.git/dandi-compute-$BRANCH.lock"
LOCK_TIMEOUT_SECONDS=600
LAUNCHER="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# monitor_history.py needs only a Python 3; these are tried before the one on PATH.
PYTHONS=(
    /orcd/data/dandi/001/environments/name-datalad_env/bin/python
    /orcd/data/dandi/001/environments/name-s3+backup_env/bin/python
)

if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec "$RUNNER_REPOSITORY/launcher/record.sh" logs "publish-$BRANCH" -- "$0" "$@"
fi

python=$(command -v python3)
for candidate in "${PYTHONS[@]}"; do
    [ -x "$candidate" ] && { python="$candidate"; break; }
done
[ -n "$python" ] || { echo "No Python to summarize the snapshots with." >&2; exit 1; }

# Commits need an identity even where git has none configured.
git config user.email > /dev/null 2>&1 || export GIT_AUTHOR_NAME="DANDI Compute" GIT_AUTHOR_EMAIL="dandi-compute@users.noreply.github.com" \
    GIT_COMMITTER_NAME="DANDI Compute" GIT_COMMITTER_EMAIL="dandi-compute@users.noreply.github.com"

exec 9> "$LOCK_FILE" || { echo "Cannot open $LOCK_FILE." >&2; exit 1; }
if ! flock -w "$LOCK_TIMEOUT_SECONDS" 9; then
    echo "Timed out waiting for $LOCK_FILE; the next run publishes the history." >&2
    exit 1
fi

# The worktree, made afresh when it is missing or broken; whatever it held is on GitHub.
if ! top=$(git -C "$WORKTREE" rev-parse --show-toplevel 2> /dev/null) || [ "$top" != "$(cd "$WORKTREE" && pwd -P)" ]; then
    rm -rf "$WORKTREE"
    git -C "$LOG_REPOSITORY" worktree prune
    mkdir -p "$(dirname "$WORKTREE")" && git -C "$LOG_REPOSITORY" worktree add -q --detach "$WORKTREE" \
        || { echo "Could not make the worktree $WORKTREE." >&2; exit 1; }
fi
cd "$WORKTREE" || exit 1

# The day branches on GitHub, oldest first. The cluster's clock is US Eastern, as the branches' names are.
mapfile -t days < <(git ls-remote --heads origin 'monitor/20*' | sed -n 's#.*refs/heads/monitor/\([0-9-]*\)$#\1#p' | sort)
[ "${#days[@]}" -gt 0 ] || { echo "No monitor day branches on GitHub." >&2; exit 1; }
today=$(date +%F)
yesterday=$(date -d yesterday +%F)

runner_commit=$(git -C "$RUNNER_REPOSITORY" rev-parse --short HEAD 2> /dev/null || echo unknown)
for attempt in 1 2 3; do
    git rebase --abort > /dev/null 2>&1
    git reset -q --hard
    git clean -qfd
    git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2> /dev/null
    if git rev-parse --verify -q "refs/remotes/origin/$BRANCH" > /dev/null; then
        git checkout -q -B "$BRANCH" "origin/$BRANCH"
    else
        # The first publication starts the branch from main, as every branch of the repository is.
        git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" && git checkout -q -B "$BRANCH" origin/main
    fi || { echo "Could not check out $BRANCH in $WORKTREE." >&2; sleep $((attempt * 5)); continue; }

    mkdir -p "$DIRECTORY"
    made=()
    for day in "${days[@]}"; do
        file="$DIRECTORY/$day.jsonl"
        [ -s "$file" ] && [ "$day" != "$today" ] && [ "$day" != "$yesterday" ] && continue
        ref="refs/remotes/origin/monitor/$day"
        if ! git fetch -q --depth 1 origin "+refs/heads/monitor/$day:$ref" 2> /dev/null; then
            echo "Could not fetch monitor/$day; its file waits for the next run." >&2
            continue
        fi
        "$python" "$LAUNCHER/monitor_history.py" --repository . --ref "$ref" --output "$file" && made+=("$day")
    done
    git add -- "$DIRECTORY"
    if git diff --cached --quiet; then
        echo "$BRANCH already holds the history of ${#days[@]} days."
        exit 0
    fi
    git commit -q -m "[DANDI Compute] monitor history: ${made[*]} (runner $runner_commit)" || exit 1
    if git push -q origin "$BRANCH"; then
        echo "Published the history of ${made[*]} to $BRANCH."
        exit 0
    fi
    sleep $((attempt * 5))
done
echo "Could not push $BRANCH to GitHub; the next run tries again." >&2
exit 1
