#!/usr/bin/env bash
#
# Start the "Create job capsules" workflow when qualifying assets are waiting for a job capsule.
# Run from cron once a day (see launcher/trigger_github_action_cron.sh).
exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/trigger_github_action_cron.sh \
  create prepare-queue.yml -- dandicompute jobs creatable --silent
