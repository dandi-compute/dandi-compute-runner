"""Drop `system` and `env` from the duct info.json files given as arguments.

duct records the host, user, OS and SLURM variables of every run in info.json; the global logs
keep only the command, its resource usage and its outcome (see launcher/record.sh). Files that
are not duct's info.json, or that hold neither key, are left as they are.
"""

import json
import sys

DROPPED_KEYS = ("system", "env")

for path in sys.argv[1:]:
    try:
        with open(path) as file:
            info = json.load(file)
    except (OSError, ValueError):
        continue
    if not isinstance(info, dict) or "duct_version" not in info or not any(key in info for key in DROPPED_KEYS):
        continue
    for key in DROPPED_KEYS:
        info.pop(key, None)
    with open(path, "w") as file:
        json.dump(info, file)
