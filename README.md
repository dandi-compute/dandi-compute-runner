# DANDI Compute (Runner)

Automatic CRON-based submission of jobs from the [DANDI Compute: AIND Queue](https://github.com/dandi-compute/queue).



## Why doesn't this repository allow Pull Requests from external forks?

This repository uses a self-hosted runner instead of GitHub-hosted Actions runners.

This means that external users could fork and submit a pull request that contains code modifications that might expose secrets or other hostile actions.

While this could be mitigated through careful permissioning and approval of run triggers before accepting contributions, it is much safer overall to simply disable them.

If you have any questions or suggestions, please raise an Issue instead.

The repository is kept public to allow anyone to see the runtime logs of the submission process, as well as the success/failure/timestamp of the triggers.



## How to setup the runners

1. Go to Settings -> Actions -> Runners -> New self-hosted runner -> Linux
2. Log into https://engaging-ood.mit.edu/ -> Open a new cluster shell
3. `cd /orcd/data/dandi/001/dandi-compute/dandi-compute-runner`
4. Follow copy & paste instructions from Settings
5. Use the default runner group
6. Give the runner the name `submitter`
7. Add the labels `mit`, `engaging`, and `submitter`
8. Use the default work directory
9. On the login node, install the crontab from [`launcher/crontab`](launcher/crontab):

   ```bash
   crontab /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/crontab
   ```

   That file is the only copy of the crontab. It replaces the whole user crontab, including the backup jobs it also lists. It is reinstalled automatically (see [Keeping the crontab installed](#keeping-the-crontab-installed)), so change the file rather than the live crontab.

The runner itself runs as a 12-hour Slurm job on `mit_preemptable` with 4 GB of memory ([`launcher/launch_submitter.sh`](launcher/launch_submitter.sh)). Every step of the workflows on this runner runs inside that job and shares its memory with the runner and with the DataLad and duct that record the step. A step that goes over it is killed with exit code 137. A change to the job's resources takes effect when the runner is next relaunched. To apply one sooner, cancel the `DANDI-Compute-Submitter` job while no workflow is running on it, and cron resubmits it within a minute.

## Keeping the crontab installed

The cluster's periodic cleanup can wipe the user crontab on the login node. That stops every entry in it, including the one that relaunches the runner (which runs as a 12-hour Slurm job), so the runner goes offline at its next time limit and the cluster triggers stop.

```
source /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/install_crontab.sh
```

[`launcher/install_crontab.sh`](launcher/install_crontab.sh) reinstalls `launcher/crontab` whenever the existing crontab differs from it. Two things run it:

- The [Refresh crontab](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/refresh-crontab.yml) workflow, every hour on the runner. Its schedule is on GitHub, so it still runs when the crontab is gone, and it is what sends the runner offline email (see [When the runner is offline](#when-the-runner-is-offline)).
- [`launcher/revive.sh`](launcher/revive.sh), a Slurm job that resubmits itself every hour.

If both the crontab and the runner are gone, reinstall the crontab by hand from a login node shell, and cron relaunches the runner within a minute.

## When the runner is offline

The runner is usually offline only briefly, between the end of its 12-hour Slurm job (or a preemption) and the relaunch, so an offline runner is not treated as a failure and sends no email until it has lasted 3 days.

- Workflows that run unattended (Process AIND Queue, Create job capsules, Update container images, Clean work directory and Refresh crontab) start with a GitHub-hosted **Check runner is online** job ([`.github/actions/check-runner`](.github/actions/check-runner/action.yml)). While the runner is offline, it skips the self-hosted job and the run still succeeds, with a notice saying so. Create job capsules, Update container images and Clean work directory first wait up to 60 minutes for the runner to come back. Process AIND Queue does not wait, since the login node dispatches it again 15 minutes later while there is work. Skipped work is not retried until the workflow's next run.
- Workflows that are only started by hand (Archive job, Prepare AIND test job, Update codebase) have no check. While the runner is offline, their job waits for it in GitHub's queue and runs once the runner is back. GitHub fails a self-hosted job that has waited about a day.
- Only [Refresh crontab](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/refresh-crontab.yml) reports an outage. When it finds the runner offline, its **Runner offline watchdog** job looks for the newest run of Refresh crontab that got onto the runner. If there is none from the last 72 hours (`OFFLINE_ALERT_HOURS`), the watchdog fails and the runner offline email goes out, at most once a day. GitHub's own email about the failed run comes on every run of Refresh crontab until the runner is back.

## Global logs

Everything that runs on the cluster outside a job capsule is recorded in
[dandi-compute-global-logs](https://github.com/dandi-compute/dandi-compute-global-logs), checked out at `/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs`. That covers every step of the self-hosted workflows, the cron trigger for dispatching, the submissions of the [S3 backup](#s3-backup) jobs, the daily [error report](#error-reports), a `squeue` snapshot every 5 minutes and a disk usage snapshot every 30 minutes ([`launcher/disk.sh`](launcher/disk.sh): `df` for the DANDI project directories, then the home directory's quota report from `~/orcd/.quota`, the one shown at login, with its usage and limits on space and on the number of files; `df` of the home directory would only show the filesystem it shares with every user). The logs of job capsules themselves stay with each capsule and go to DANDI with it.

[`launcher/record.sh`](launcher/record.sh) does the recording: `record.sh KIND NAME -- COMMAND...` runs the command and records it on that day's branch for its kind (`logs/YYYY-MM-DD`, `errors/YYYY-MM-DD`, `monitor/YYYY-MM-DD` or `disk/YYYY-MM-DD`, so the kinds update independently), under `logs/{timestamp}-{name}/` or, for the snapshot kinds and grouped by hour, `monitor/{HH}/{timestamp}-squeue/` and `disk/{HH}/{timestamp}-usage/`. A snapshot also writes its path relative to its kind's directory (`{HH}/{timestamp}-{name}`) to that kind's `LATEST` (`monitor/LATEST`, `disk/LATEST`), so the newest one can be looked up without listing the directory. Once a snapshot's day branch is on GitHub, it also points the persistent `monitor/latest` or `disk/latest` branch at that day: its one file, `LATEST`, names the newest day branch of that kind, so the newest snapshot can be found even on a day with no branch, such as just after midnight or while the snapshots are down. Only each day's first snapshot changes it, and it never moves back to an earlier day.

- Each record is a `datalad run` commit holding the exact command, its directory and its exit status. The command's `stdout` and `stderr` are saved beside it, and it runs inside duct, which saves its `info.json` and `usage.jsonl` under `.duct/`. DataLad and duct come from `/orcd/data/dandi/001/environments/name-datalad_env`, which the Update codebase workflow creates when it is missing, or else from the LFP capsules' `name-lfp_environment`; without either the command is recorded with plain git.
- The record is made in a throwaway clone and then moved onto the day's branch in the shared checkout's worktree for its kind (`untracked/worktrees/logs`, `untracked/worktrees/errors`, `untracked/worktrees/monitor` or `untracked/worktrees/disk`), which is locked only for that move and the push. Each kind has its own worktree and lock, so the snapshots and the tasks never wait on each other.
- Recording never stops the work: the command always runs, its exit status is passed through, and anything that went wrong is pushed in the record's `record.log`. If the shared checkout is busy or broken, the record is pushed straight to GitHub. If GitHub cannot be reached, it is kept in `untracked/unpushed/` and delivered with the next record.
- The day branches are ephemeral: each kind's first delivery of the day deletes from GitHub its day branches older than 30 days (`DAY_BRANCH_RETENTION_DAYS` in `record.sh`), and notes which in that record's `record.log`. A day branch the shared checkout could not push for that long is dropped as well. `main` and `monitor/latest` are never deleted; when `monitor/latest` names a deleted day, the dashboard falls back to listing the `monitor/` branches.
- Workflow steps are recorded through each self-hosted job's `defaults.run.shell`, which also keeps the step's script and the run's URL. That shell starts in plain bash and hands the step to `record.sh` only when it is on the machine, so a checkout that predates `record.sh` still runs every step (unrecorded) and the Update codebase workflow can bring it in.

To set it up, clone the repository with a token that can push to it (contents: write) in its URL:

```bash
git clone https://x-access-token:<token>@github.com/dandi-compute/dandi-compute-global-logs /orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs
chmod 600 /orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs/.git/config
```

Every push goes through that clone's origin. Since duct samples the command line of every process a step starts, every file and message of a record passes through [`launcher/redact.sed`](launcher/redact.sed) before it is committed, which masks GitHub tokens, `Authorization` headers, credentials in URLs and DANDI API keys, including the one `record.sh` itself runs with wherever it appears. duct's `info.json` also leaves out the `system` and `env` duct records (host, user, OS, SLURM variables), through [`launcher/strip_duct_info.py`](launcher/strip_duct_info.py). Records made before that masking can hold a token, which GitHub's push protection rejects; [`launcher/scrub_global_logs.sh`](launcher/scrub_global_logs.sh) masks every record the shared checkout has not pushed yet, rewriting only the file versions that need it without checking anything out, and the next record pushes them.

## Home directory cleanup

The home directory has a quota on both space and number of files (shown in the disk usage snapshots), and a few caches and logs fill it. As part of the cluster-wide cleanup, cron on the login node runs [`launcher/clean_home.sh`](launcher/clean_home.sh) every Sunday at 04:00 (login node time), which deletes:

- the Apptainer blobs older than 7 days in `~/.apptainer/cache/blob/blobs/sha256/`
- every dandi-cli log in `~/.local/state/dandi-cli/log/`
- everything in Bazel's output root, `~/.cache/bazel/_bazel_$USER/`

Each run is recorded in the global logs under `logs/`, with what each step deleted. A directory that is not there is skipped, and the run exits non-zero if any step failed. To run it by hand from a login node shell (it records itself there too):

```bash
/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/clean_home.sh
```

## S3 backup

The cluster keeps a mirror of the DANDI S3 bucket on the project partitions, and every job capsule reads its input blob from it. The jobs that keep it up to date come from [simple-s3-backup](https://github.com/dandi/simple-s3-backup), checked out at `/orcd/data/dandi/001/backup/simple-s3-backup`. This repository does not update that checkout. The crontab submits the jobs through [`launcher/backup.sh`](launcher/backup.sh), which names them:

| Job | Cron (login node time) | What it does |
|---|---|---|
| `DANDI-Backup-Blobs` | daily at 22:00 | Copies new blobs, in a 16-task array with one task per first hex digit of the content ID |
| `DANDI-Backup-Nonblobs` | daily at 18:00 | Copies everything outside `blobs/` and `zarr/` |
| `DANDI-Update-Backup-Dashboard` | daily at 06:00 | Updates the [backup-status](https://github.com/dandi/backup-status) dashboard |

The Zarr backup (`backup.sh zarr`) has been disabled since May 2026.

Each submission is recorded in the global logs under `logs/{timestamp}-backup-{kind}/`, with the job ID `sbatch` gave it. Each job writes its own output to `/orcd/data/dandi/001/backup/logs/{job name}-{job ID}.log`, or `{job name}-{array job}_{task}.log` for the arrays. Logs older than 30 days are deleted at the next submission.

The [Check backup](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/check-backup.yml) workflow checks the backup every day at 16:37 UTC and emails when it finds a problem.

- **Check backup jobs** runs `sacct` on the runner for the jobs above. It fails when one of them was not submitted in the last 24 hours, or when a task of one ended in that time as `FAILED`, `OUT_OF_MEMORY`, `NODE_FAIL`, `BOOT_FAIL` or `DEADLINE`. The email then shows the end of the first two failed tasks' logs. A task that timed out, was preempted or was cancelled only gives a warning. The check is skipped while the runner is offline.
- **Check mirror growth** runs on a GitHub-hosted runner and reads the history of backup-status. It fails when the dashboard's count of mirrored blobs has not grown in 3 days while the bucket's has. That catches a backup that stops copying without any task failing.

The email goes out on every failed run, so at most once a day. backup-status has checks of its own too, which email when a partition is over 85% full or the dashboard has not been updated for 3 days.

## Error reports

The [Report errors](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/report-errors.yml) workflow records what is going wrong on the cluster in the global logs, under `errors/` on the day's `errors/YYYY-MM-DD` branch, so it can be read without a shell on the cluster. It runs every day at 15:07 UTC and by hand. A run takes 20 to 30 minutes and holds the runner, so it does not run on pull requests. To try a change to it before merging, dispatch it on the pull request's branch, which runs that branch's copy of the workflow and the script. [`launcher/report_errors.sh`](launcher/report_errors.sh) makes each section a record of its own, `errors/{timestamp}-{section}/`.

| Section | What it records |
|---|---|
| `backup-checkout` | The simple-s3-backup checkout the backup jobs run from: its state, its local changes against GitHub's `main`, and its job scripts as deployed. Then the crontab installed on the login node, against `launcher/crontab`. |
| `backup-environment` | The blob backup job's setup, replayed in cron's environment with every failing command reported, then `s3backup`, `s5cmd` and a listing of the bucket. Also the lock files, whether the blob mirror's directories are writable, and when they last changed. |
| `backup-reproduce` | One task of the blob backup, submitted the way cron submits it but traced, with its log and `sacct` record. Every run but the scheduled one does this. A task that works goes on to back up its share of the bucket, as the nightly one would. |
| `slurm-failures` | Every job of the last 7 days that did not complete, grouped by name, state and exit code. Then the output of each failed job (a Nextflow task's `.command.err`, a dispatch task's log or a backup task's log) grouped by its error, with paths and IDs masked, and the end of one log for each. |
| `missing-blobs` | Every job capsule prepared on the cluster whose input blob is not in the mirror, or is on the other partition, and whether its script already ran. |
| `home-usage` | The home directory's quota report and the directories holding the most files and space. Every job of this user writes there, and the DANDI CLI opens a log file there on every call, so a full quota on either fails them all. |
| `diagnosis` | What the sections above point to: the first step that failed in the backup and its likely cause, and the most frequent failures. It is also the run's summary on GitHub. |

The records are public, so the report names the runner's user and home directory only as `<user>` and `~`, and every record passes through `launcher/redact.sed` like any other. Nothing in it fails the run or sends email. The Check backup workflow does the alerting.

## Queue state

The [Refresh state](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/refresh-state.yml) workflow rewrites `derivatives/jobs.tsv`, `paths.tsv` and their sidecars in the job capsules (001697) and failed runs archive (001873) Dandisets. It reads only from DANDI and writes only to DANDI, so it runs on a GitHub-hosted runner rather than on the cluster. It runs every hour and after each run of the workflows that change the queue, and uploads only the tables whose content changed. Its Python environment is cached per commit of dandi-compute-core's `main`.

## How to delete failed runs (manual)

Use the [Delete failed runs](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/delete-failed-runs.yml) workflow dispatch. It runs `dandicompute archive delete`, which deletes from the failed runs archive (001873) and nothing else. Select either one capsule by its `job` ID, or every capsule of one pipeline version with `version` and `pipeline` together. A version must always be paired with its pipeline, so one version number cannot clobber the capsules of every pipeline that shares it. Like Refresh state, it runs on a GitHub-hosted runner with the same cached environment. It only previews by default: the run's summary lists the capsules that would be deleted along with the provenance of each (job ID, status, source asset, pipeline, exact version, params, config and codebase), and nothing is deleted until you dispatch it again with `preview` cleared. Refresh state runs after it, so the archive's `jobs.tsv` drops the deleted capsules.

| Input | Description | Default |
|---|---|---|
| `job` | Job ID of the one capsule to delete, such as `job-260916a1b2c3`. Leave `version` empty and `pipeline` as `none` with it. | _(none)_ |
| `version` | Pipeline version whose capsules are deleted, with or without the leading `v`. A version without build metadata, such as `v1.3.0`, also selects its builds, such as `v1.3.0+b268fd2`. Requires `pipeline`. | _(none)_ |
| `pipeline` | The pipeline whose capsules of `version` are deleted (`aind+ephys` or `lfp`). Required with `version`. | `none` |
| `preview` | Only list the capsules that would be deleted, with the provenance of each. | `true` |

## SLURM limits

`sacctmgr show qos format=Name,MaxTRESPU -P | grep '^mit_' | grep -v '|$'`:

```
mit_normal|cpu=96,mem=386G
mit_normal_gpu|cpu=32,gres/gpu=2,mem=515G
mit_quicktest|cpu=48,mem=193G
mit_preemptable|cpu=1024,gres/gpu=4,mem=4T
```



## How to process the queue (manual)

Use the [Process queue](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/process-queue.yml) workflow dispatch.

| Input | Description | Default |
|---|---|---|
| `test` | Run in test mode (the temporary submission directory will not be deleted). | `false` |



## Triggering workflows from the cluster

The workflows that do recurring work have no GitHub schedule. A cron on the login node checks for work first and starts the workflow through `workflow_dispatch` only when there is some, so the runner only runs them when they have something to do. A check that finds nothing sends nothing to GitHub; each check is still recorded in the global logs.

| Workflow | Cron | Started when |
|---|---|---|
| [Process AIND Queue](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/process-queue.yml) | every 15 minutes, [`dispatch_github_action_cron.sh`](launcher/dispatch_github_action_cron.sh) | `dandicompute jobs pending` finds job capsules waiting to be submitted |
| [Create job capsules](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/prepare-queue.yml) | daily at midnight (login node time), [`create_github_action_cron.sh`](launcher/create_github_action_cron.sh) | `dandicompute jobs creatable` finds qualifying assets without a job capsule |

Both go through [`launcher/trigger_github_action_cron.sh`](launcher/trigger_github_action_cron.sh). It skips when many jobs are held for maintenance, and fails loudly (rather than skipping) when the check itself fails.

## How to create job capsules (manual)

Use the [Create job capsules](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/prepare-queue.yml) workflow dispatch.

| Input | Description | Default |
|---|---|---|
| `limit` | Maximum number of job capsules to create per pipeline and parameter set. Creation gives each asset a capsule for every parameter set (one per spike sorter for `aind+ephys`) before the next asset, so this is a limit on assets. | `5` |

## The AIND Nextflow environment

AIND job capsules run Nextflow from a conda environment on the cluster, which dandi-compute-core names in each capsule's `submit.sh`. The [Update codebase](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/update-codebase.yml) workflow provisions it at `/orcd/data/dandi/001/environments/name-nextflow_version-25+10+4_environment` when it is missing, with Nextflow 25.10.4 and the DANDI CLI. AIND ephys pipeline 1.5.0 needs Nextflow 25.10 or later for the `nf-schema` plugin it validates its parameters with. The workflow also installs that plugin into `~/.nextflow/plugins`, so capsules that start together do not all download it. Capsules formed before this environment keep the older `name-nextflow_environment` their `submit.sh` names.

## How AIND container images are cached

Nextflow pulls each AIND step's container image into `work/apptainer_cache/` the first time a step needs it, inside the capsule's 1 GB driver job. Building a multi-gigabyte image takes far more memory than that, so the pull is killed and the capsule fails before any step runs.

The [Update container images](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/update-container-images.yml) workflow pulls them ahead of time instead. It works out the image tag of the latest local pipeline version, and when any of its images is not cached yet it runs the pipeline's own `pull_pipeline_images.sh` in a 32 GB job on `mit_normal`. Pipeline 1.5.0 added DARTsort, which has an image of its own (`aind-ephys-spikesort-dartsort`) that the upstream script does not pull, so the job pulls it directly whenever the release's `environment/images.json` names it. Lupin runs in the base image. The workflow waits for the job, prints its log, and fails if an image is still missing afterwards. It runs after every [Update codebase](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/update-codebase.yml) run, since that is when a new pipeline tag arrives, and daily an hour before job capsules are created.

| Input | Description | Default |
|---|---|---|
| `version` | AIND ephys pipeline release tag whose images to cache. | latest local tag |

To do the same by hand from a cluster shell, run the script where it sits in the pipeline checkout rather than a copy of it, since from release 1.4.1 it reads the image names from `environment/images.json` beside it (with `jq`). From release 1.4.0 the image tag is the release itself, as in `pipeline/pipeline_version.txt`, and the script is under `scripts/`. Earlier releases tag images `si-` plus the `SPIKEINTERFACE_VERSION` in `pipeline/capsule_versions.env` and keep the script at the top level.

```bash
cd /orcd/data/dandi/001/dandi-compute
sbatch --mem=32GB --cpus-per-task=8 --partition=mit_normal --time=04:00:00 --wrap "source /etc/profile.d/modules.sh && module load apptainer && bash aind-ephys-pipeline/scripts/pull_pipeline_images.sh --cache $PWD/work/apptainer_cache --tag 1.5.0"
```

## How to prepare a specific AIND job (manual)

To prepare one specific asset, run `dandicompute prepare aind` from a cluster shell with `DANDI_API_KEY` set. Name the asset by `--id`, or by `--dandiset` and `--dandipath`. `--version` is required, `--params` and `--config` default to `default`, and `--submit` submits the job once it is prepared.

```bash
cd /orcd/data/dandi/001/dandi-compute
dandicompute prepare aind --base /orcd/data/dandi/001/dandi-compute --id <content-id> --version <pipeline-version>
```

### Prepare AIND test job

The [Prepare AIND test job](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/prepare-aind-test.yml) workflow prepares the job capsule for the test asset.

| Input | Description | Default |
|---|---|---|
| `config` | Registered configuration key. | `default` |
| `params` | Parameters key. | `default` |
