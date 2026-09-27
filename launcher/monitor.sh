#!/bin/bash
#
# Record a snapshot of this user's SLURM jobs in the global logs repository, under monitor/ on
# the day's branch. Run by the crontab on the login node every 5 minutes; it is a script rather
# than a crontab line because cron cannot take the `%` in squeue's format.
exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh monitor squeue -- \
    squeue --me --format="%.10i %15P %40j %10u %.2t %.10M %.6D %.2C %.10m %30R"
