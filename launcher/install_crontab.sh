#!/bin/bash
#
# install_crontab.sh - Install launcher/crontab on the login node unless it is installed already.
#
# The cluster's periodic cleanup can wipe the user crontab, which stops every cron entry in it,
# including the one that relaunches the runner. revive.sh and the Refresh crontab workflow both
# call this to put it back.
#
# crontab is PAM-blocked on compute nodes and cron only runs where the tab is installed, so the
# install has to happen on the login node over ssh. The command must be an argument to ssh itself;
# a bare `ssh host` opens an interactive shell (which dies without a tty) and anything on the next
# line runs locally on the compute node. BatchMode makes ssh fail fast instead of hanging on a
# password prompt it can never answer.
#
# Exits 0 when the crontab was already installed or is now, and non-zero when it could not be.

set -uo pipefail

LOGIN_HOST="login007"
CRONTAB_FILE="/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/crontab"

if ! getent hosts "$LOGIN_HOST" > /dev/null; then
    echo "$(date) cannot resolve ${LOGIN_HOST} from $(hostname)"
fi

ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$LOGIN_HOST" \
    "if crontab -l 2> /dev/null | cmp -s - '${CRONTAB_FILE}'; then
         echo \"crontab on \$(hostname) already matches ${CRONTAB_FILE}\"
     else
         crontab '${CRONTAB_FILE}' && echo \"crontab installed on \$(hostname), \$(crontab -l | grep -c sbatch) sbatch entries\"
     fi"
status=$?
if [ "$status" -ne 0 ]; then
    echo "$(date) crontab install FAILED (ssh exit ${status}) — see ssh error above"
fi
exit "$status"
