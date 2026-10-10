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

   That file is the only copy of the crontab. It replaces the whole user crontab, including the backup jobs it also lists. `launcher/revive.sh` reinstalls it the same way every hour, so change the file rather than the live crontab.

## Global logs

Everything that runs on the cluster outside a job capsule is recorded in
[dandi-compute-global-logs](https://github.com/dandi-compute/dandi-compute-global-logs), checked out at `/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs`. That covers every step of the self-hosted workflows, the cron trigger for dispatching, and a `squeue` snapshot every 5 minutes. The logs of job capsules themselves stay with each capsule and go to DANDI with it.

[`launcher/record.sh`](launcher/record.sh) does the recording: `record.sh KIND NAME -- COMMAND...` runs the command and records it on that day's branch for its kind (`logs/YYYY-MM-DD` or `monitor/YYYY-MM-DD`, so the two update independently), under `logs/{timestamp}-{name}/` or, grouped by hour, `monitor/{HH}/{timestamp}-{name}/`. A monitor snapshot also writes its path relative to `monitor/` (`{HH}/{timestamp}-{name}`) to `monitor/LATEST`, so the newest one can be looked up without listing `monitor/`.

- Each record is a `datalad run` commit holding the exact command, its directory and its exit status. The command's `stdout` and `stderr` are saved beside it, and it runs inside duct, which saves its `info.json` and `usage.jsonl` under `.duct/`. DataLad and duct come from `/orcd/data/dandi/001/environments/name-datalad_env`, which the Update codebase workflow creates when it is missing, or else from the LFP capsules' `name-lfp_environment`; without either the command is recorded with plain git.
- The record is made in a throwaway clone and then moved onto the day's branch in the shared checkout's worktree for its kind (`untracked/worktrees/logs` or `untracked/worktrees/monitor`), which is locked only for that move and the push. Each kind has its own worktree and lock, so the snapshots and the tasks never wait on each other.
- Recording never stops the work: the command always runs, its exit status is passed through, and anything that went wrong is pushed in the record's `record.log`. If the shared checkout is busy or broken, the record is pushed straight to GitHub. If GitHub cannot be reached, it is kept in `untracked/unpushed/` and delivered with the next record.
- Workflow steps are recorded through each self-hosted job's `defaults.run.shell`, which also keeps the step's script and the run's URL. That shell starts in plain bash and hands the step to `record.sh` only when it is on the machine, so a checkout that predates `record.sh` still runs every step (unrecorded) and the Update codebase workflow can bring it in.

To set it up, clone the repository with a token that can push to it (contents: write) in its URL:

```bash
git clone https://x-access-token:<token>@github.com/dandi-compute/dandi-compute-global-logs /orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs
chmod 600 /orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs/.git/config
```

Every push goes through that clone's origin. Since duct samples the command line of every process a step starts, every file and message of a record passes through [`launcher/redact.sed`](launcher/redact.sed) before it is committed, which masks GitHub tokens, `Authorization` headers, credentials in URLs and DANDI API keys, including the one `record.sh` itself runs with wherever it appears. duct's `info.json` also leaves out the `system` and `env` duct records (host, user, OS, SLURM variables), through [`launcher/strip_duct_info.py`](launcher/strip_duct_info.py). Records made before that masking can hold a token, which GitHub's push protection rejects; [`launcher/scrub_global_logs.sh`](launcher/scrub_global_logs.sh) masks every record the shared checkout has not pushed yet, rewriting only the file versions that need it without checking anything out, and the next record pushes them.

## Queue state

The [Refresh state](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/refresh-state.yml) workflow rewrites `derivatives/jobs.tsv`, `paths.tsv` and their sidecars in the job capsules (001697) and failed runs archive (001873) Dandisets. It reads only from DANDI and writes only to DANDI, so it runs on a GitHub-hosted runner rather than on the cluster. It runs every hour and after each run of the workflows that change the queue, and uploads only the tables whose content changed. Its Python environment is cached per commit of dandi-compute-core's `main`.

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



## How to create job capsules (manual)

Use the [Create job capsules](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/prepare-queue.yml) workflow dispatch.

| Input | Description | Default |
|---|---|---|
| `limit` | Maximum number of job capsules to create per pipeline. | `5` |

## How AIND container images are cached

Nextflow pulls each AIND step's container image into `work/apptainer_cache/` the first time a step needs it, inside the capsule's 1 GB driver job. Building a multi-gigabyte image takes far more memory than that, so the pull is killed and the capsule fails before any step runs.

The [Update container images](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/update-container-images.yml) workflow pulls them ahead of time instead. It works out the image tag of the latest local pipeline version, and when any of its images is not cached yet it runs the pipeline's own `pull_pipeline_images.sh` in a 32 GB job on `mit_normal`. The workflow waits for the job, prints its log, and fails if an image is still missing afterwards. It runs after every [Update codebase](https://github.com/dandi-compute/dandi-compute-runner/actions/workflows/update-codebase.yml) run, since that is when a new pipeline tag arrives, and daily an hour before job capsules are created.

| Input | Description | Default |
|---|---|---|
| `version` | AIND ephys pipeline release tag whose images to cache. | latest local tag |

To do the same by hand from a cluster shell, take the tag from the pipeline's `pipeline/capsule_versions.env`. From release 1.4.0 it is the `CONTAINER_TAG` there, and the script is under `scripts/`. Earlier releases tag images `si-` plus their `SPIKEINTERFACE_VERSION` and keep the script at the top level.

```bash
cd /orcd/data/dandi/001/dandi-compute
sbatch --mem=32GB --cpus-per-task=8 --partition=mit_normal --time=04:00:00 --wrap "source /etc/profile.d/modules.sh && module load apptainer && bash aind-ephys-pipeline/scripts/pull_pipeline_images.sh --cache $PWD/work/apptainer_cache --tag 1.4.0"
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
