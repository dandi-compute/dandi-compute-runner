#!/bin/bash
#SBATCH --job-name=revive
#SBATCH --output=/orcd/data/dandi/001/dandi-compute/tmp/revive-logs/%x-%j.out
#SBATCH --time=00:10:00
#SBATCH --partition=mit_preemptable
#SBATCH --mem=100MB
#SBATCH --cpus-per-task=1

set -uo pipefail

INTERVAL_MIN=60
SELF="/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/revive.sh"
LOGIN_HOST="login007"
CRONTAB_FILE="/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/crontab"

OTHERS=$(squeue --noheader --name="$SLURM_JOB_NAME" --user="$USER" \
         --states=PENDING,RUNNING --format="%A" \
         | grep -v "^${SLURM_JOB_ID}$" || true)

if [ -n "$OTHERS" ]; then
    echo "$(date) duplicate ${SLURM_JOB_NAME} found ($OTHERS) — exiting."
    exit 0
fi

sbatch --begin="now+${INTERVAL_MIN}minutes" "$SELF"

echo "$(date) running on $(hostname), reinstalling crontab on ${LOGIN_HOST}"

# crontab is PAM-blocked on compute nodes and cron only runs where the tab is
# installed, so the install has to happen on the login node over ssh. The
# command must be an argument to ssh itself; a bare `ssh host` opens an
# interactive shell (which dies without a tty) and anything on the next line
# runs locally on the compute node. BatchMode makes ssh fail fast instead of
# hanging on a password prompt it can never answer.
if ! getent hosts "$LOGIN_HOST"; then
    echo "$(date) cannot resolve ${LOGIN_HOST} from $(hostname)"
fi

if ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
       "$LOGIN_HOST" "crontab '${CRONTAB_FILE}' && echo \"crontab installed on \$(hostname), \$(crontab -l | grep -c sbatch) sbatch entries\""; then
    echo "$(date) crontab reinstall succeeded"
else
    echo "$(date) crontab reinstall FAILED (ssh exit $?) — see ssh error above"
fi
