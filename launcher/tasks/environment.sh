# Sourced by every scheduled task before it runs its one dandicompute command.
#
# The tasks run as plain SLURM jobs rather than on the GitHub runner, so the secrets the
# workflows used to inject come from ~/.dandi_env instead. The job arrays a dispatch submits
# inherit this environment, so it has to carry everything a capsule run needs as well:
# DANDI_API_KEY, DANDI_DEVEL and KACHERY_API_KEY (and DANDICOMPUTE_OOP_FAILSAFE_LOG if used).

BASE_DIRECTORY=/orcd/data/dandi/001/dandi-compute

# ~/.dandi_env and lmod's init both reference unset variables, so nounset is relaxed around them.
set +u
# shellcheck disable=SC1091
source "$HOME/.dandi_env"
source /etc/profile.d/modules.sh
module load miniforge
conda activate /orcd/data/dandi/001/environments/name-dandi+compute_env
set -u

: "${DANDI_API_KEY:?DANDI_API_KEY is empty or unset after sourcing ~/.dandi_env}"

cd "$BASE_DIRECTORY"
echo "$(date '+%F %T') ${SLURM_JOB_NAME:-task} ${SLURM_JOB_ID:-} starting on $(hostname)"
