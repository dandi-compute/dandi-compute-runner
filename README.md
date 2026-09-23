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
9. Setup a `crontab` with the following:

```
*/1 * * * * /bin/bash -l -c 'flock -n /orcd/data/dandi/001/dandi-compute/flocks/monitor.lock -c "/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/guarded-submit -- sbatch --output /dev/null --error=/dev/null /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/launch_monitor.sh" || echo "$(date): lock held, skipping submit"' > /dev/null 2>&1

# For whatever reason, this particular job is sensitive to the usage of `/bin/bash -l` in order to 'behave properly'. Otherwise the SLURM job does run, the self-hosted runner is active, but the conda init does not trigger and so no environment is found.
*/1 * * * * /bin/bash -l -c 'flock -n /orcd/data/dandi/001/dandi-compute/flocks/submitter.lock -c "/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/guarded-submit -- sbatch --output /dev/null --error=/dev/null /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/launch_submitter.sh" || echo "$(date): lock held, skipping submit"' > /dev/null 2>&1
```

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
