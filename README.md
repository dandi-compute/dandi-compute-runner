# DANDI Compute (Runner)

Automatic CRON-based submission of jobs from the [DANDI Compute: AIND Queue](https://github.com/dandi-compute/queue).



## Why doesn't this repository allow Pull Requests from external forks?

This repository uses a self-hosted runner instead of GitHub-hosted Actions runners.

This means that external users could fork and submit a pull request that contains code modifications that might expose secrets or other hostile actions.

While this could be mitigated through careful permissioning and approval of run triggers before accepting contributions, it is much safer overall to simply disable them.

If you have any questions or suggestions, please raise an Issue instead.

The repository is kept public to allow anyone to see the runtime logs of the submission process, as well as the success/failure/timestamp of the triggers.



## Global logs

Every operation on the cluster records itself in the global logs repository,
[dandi-compute-global-logs](https://github.com/dandi-compute/dandi-compute-global-logs), checked out at `/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs`. That covers the scheduled tasks, every step of the workflows below, and a `squeue` snapshot every 5 minutes. The logs of job capsules themselves stay with each capsule and go to DANDI with it.

Records land on a branch per day (`YYYY-MM-DD`), under `logs/` for operations and `monitor/` for the snapshots, so old days can be dropped as branches. Each record is a `datalad run` commit, which holds the exact command, where it ran and its exit status. It is made inside [duct](https://github.com/con/duct), which adds timing and resource usage beside the command's output.

[`launcher/record.sh`](launcher/record.sh) does the recording:

```bash
launcher/record.sh logs <name> -- <command> [args...]
```

It never stops the work and never drops a record. Whatever goes wrong while recording is written to a `record.log` beside the output:

- **No DataLad:** the command still runs, and its output is committed with plain git.
- **Shared checkout busy or broken:** the record is pushed straight to GitHub.
- **GitHub unreachable:** the record is kept under `untracked/unpushed/` in the checkout, and the next record that gets through commits it under `recovered/`.

The raw output of each SLURM job and of the runner also goes to `untracked/` in the checkout, in case recording itself fails.

## Scheduled tasks

Nothing sits idle on the cluster. The crontab on the login node submits each recurring task as a short SLURM job that runs one `dandicompute` command and exits:

| Task | When | SLURM job | Runs |
|---|---|---|---|
| [`dispatch`](launcher/tasks/dispatch.sh) | every 30 minutes | `DANDI-Compute-Dispatch`, `mit_quicktest`, 15 min | `jobs dispatch --refresh` |
| [`images`](launcher/tasks/images.sh) | daily, 04:00 | `DANDI-Compute-Images`, `mit_quicktest`, 15 min | checks the latest AIND tag's container images are cached; if not, submits [`pull_images.sh`](launcher/tasks/pull_images.sh) (`DANDI-Compute-Image-Cache`, `mit_normal`, 32 GB, 4 h) |
| [`create`](launcher/tasks/create.sh) | daily, 05:00 | `DANDI-Compute-Create`, `mit_preemptable`, 1 h | `jobs create --limit 5` per pipeline, then `jobs refresh` |
| [`clean`](launcher/tasks/clean.sh) | weekly, Sunday 06:00 | `DANDI-Compute-Clean`, `mit_preemptable`, 2 h | `clean --work` |

Each cron line calls [`launcher/submit_task.sh`](launcher/submit_task.sh), which submits the task through `guarded-submit -N <job name>`. That skips the submission while a job of the same name is still pending or running, so a task that is slow to start never piles up copies of itself.

A dispatch skips any pipeline whose job array is still pending or running. When every pipeline's array is, it skips before reading anything, so an attempt while arrays churn costs seconds. Every attempt that was not skipped rewrites `jobs.tsv`.

The login node also runs, every 5 minutes, [`launcher/monitor.sh`](launcher/monitor.sh) (the `squeue` snapshot) and [`launcher/launch_runner.sh`](launcher/launch_runner.sh) (see below).

### Setup

1. The tasks run outside GitHub Actions, so the secrets the workflows inject have to come from `~/.dandi_env` instead. The job arrays a dispatch submits inherit its environment, so it needs everything a capsule run needs.

   ```bash
   export DANDI_API_KEY=...
   export DANDI_DEVEL=...
   export KACHERY_API_KEY=...
   export DANDICOMPUTE_OOP_FAILSAFE_LOG=...  # if used
   ```

2. Clone the global logs repository where the scripts expect it. Recording uses DataLad and duct from `/orcd/data/dandi/001/environments/name-datalad_env`, and records plainly without them:

   ```bash
   git clone https://x-access-token:<token>@github.com/dandi-compute/dandi-compute-global-logs /orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs
   chmod 600 /orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs/.git/config
   ```

   The token needs contents: write on dandi-compute-global-logs. Records are pushed with the clone's origin, and so is a record pushed straight to GitHub when the checkout is busy. Credentials in URLs are masked in every `record.log`.

3. On the login node, install the crontab from [`launcher/crontab`](launcher/crontab):

   ```bash
   crontab /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/crontab
   ```

   That file is the only copy of the crontab. It replaces the whole user crontab, including the backup jobs it also lists. The "Refresh state" workflow and `launcher/revive.sh` reinstall it the same way, so change the file rather than the live crontab.

## The self-hosted runner

The workflows in this repository run on a self-hosted runner labelled `submitter`. It runs on the login node rather than in a SLURM job, since its steps only do light work and submit sbatch jobs for anything heavy. The crontab calls [`launcher/launch_runner.sh`](launcher/launch_runner.sh) every 5 minutes, which starts the runner under a lock, so it comes back within 5 minutes of stopping. Its output goes to `untracked/runner/` in the global logs checkout, and each workflow step records itself there through `record.sh`.

To register the runner in the first place:

1. Go to Settings -> Actions -> Runners -> New self-hosted runner -> Linux
2. Log into https://engaging-ood.mit.edu/ -> Open a new cluster shell
3. `cd /orcd/data/dandi/001/dandi-compute/dandi-compute-runner`
4. Follow copy & paste instructions from Settings
5. Use the default runner group
6. Give the runner the name `submitter`
7. Add the labels `mit`, `engaging`, and `submitter`
8. Use the default work directory

## SLURM limits

`sacctmgr show qos format=Name,MaxTRESPU -P | grep '^mit_' | grep -v '|$'`:

```
mit_normal|cpu=96,mem=386G
mit_normal_gpu|cpu=32,gres/gpu=2,mem=515G
mit_quicktest|cpu=48,mem=193G
mit_preemptable|cpu=1024,gres/gpu=4,mem=4T
```



## How to dispatch job capsules (manual)

Use the [Dispatch job capsules](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/process-queue.yml) workflow dispatch.

| Input | Description | Default |
|---|---|---|
| `test` | Run in test mode (the temporary submission directory will not be deleted). | `false` |



## How to create job capsules (manual)

Use the [Create job capsules](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/prepare-queue.yml) workflow dispatch.

| Input | Description | Default |
|---|---|---|
| `limit` | Maximum number of job capsules to create per pipeline. | `5` |

## How AIND container images are cached

Nextflow pulls each AIND step's container image into `work/apptainer_cache/` the first time a step needs it, inside the capsule's 1 GB driver job. Building a multi-gigabyte image takes far more memory than that, so the pull is killed and the capsule fails before any step runs.

The [Update container images](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/update-container-images.yml) workflow pulls them ahead of time instead. It works out the image tag of the latest local pipeline version, and when any of its images is not cached yet it runs the pipeline's own `pull_pipeline_images.sh` in a 32 GB job on `mit_normal`. The workflow waits for the job, prints its log, and fails if an image is still missing afterwards. It runs after every [Update codebase](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/update-codebase.yml) run, since that is when a new pipeline tag arrives. The daily [`images`](launcher/tasks/images.sh) task makes the same check each morning, an hour before job capsules are created, and submits the same pull without waiting on it.

| Input | Description | Default |
|---|---|---|
| `version` | AIND ephys pipeline release tag whose images to cache. | latest local tag |

To do the same by hand from a cluster shell (the tag is `si-` plus the pipeline's `SPIKEINTERFACE_VERSION`):

```bash
cd /orcd/data/dandi/001/dandi-compute
sbatch --mem=32GB --cpus-per-task=8 --partition=mit_normal --time=04:00:00 --wrap "source /etc/profile.d/modules.sh && module load apptainer && bash aind-ephys-pipeline/pull_pipeline_images.sh --cache $PWD/work/apptainer_cache --tag si-0.104.9"
```

## How to prepare a specific AIND job (manual)

Use one of the dedicated workflow dispatches:

- [Prepare AIND job](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/prepare-aind.yml) for non-test preparation.
- [Prepare AIND test job](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/prepare-aind-test.yml) for test preparation.

### Prepare AIND job (non-test)

| Input | Description | Default |
|---|---|---|
| `id` | Content ID to process (required unless `dandiset` and `dandipath` are provided). | _(none)_ |
| `dandiset` | Dandiset ID (required unless `id` is provided). | _(none)_ |
| `dandipath` | Local Dandiset path (required unless `id` is provided). | _(none)_ |
| `config` | Registered configuration key. | `default` |
| `version` | Pipeline version. | _(none)_ |
| `params` | Parameters key. | `default` |
| `submit` | Automatically submit after preparation. | `false` |
| `silent` | Suppress output messages. | `false` |

### Prepare AIND test job

| Input | Description | Default |
|---|---|---|
| `config` | Registered configuration key. | `default` |
| `params` | Parameters key. | `default` |
