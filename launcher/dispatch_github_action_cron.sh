#!/usr/bin/env bash
#
# Start the "Process AIND Queue" workflow when job capsules are waiting to be submitted.
# Run from cron every 15 minutes (see launcher/trigger_github_action_cron.sh).
exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/trigger_github_action_cron.sh \
  dispatch process-queue.yml -- dandicompute jobs pending --silent
