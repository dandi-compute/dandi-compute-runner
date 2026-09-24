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
6. Give the runners the name `submitter` or `monitor` (correspondingly)
7. Add the labels `mit`, `engaging`, and `submitter` or `monitor` (correspondingly)
8. Use the default work directory
9. On the login node, install the crontab from [`launcher/crontab`](launcher/crontab):

   ```bash
   crontab /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/crontab
   ```

   That file is the only copy of the crontab. It replaces the whole user crontab, including the backup jobs it also lists. The "Refresh state" workflow and `launcher/revive.sh` reinstall it the same way, so change the file rather than the live crontab.

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
