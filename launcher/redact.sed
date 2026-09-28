# Masks credentials in whatever goes into a global logs record: record.sh runs every file of a
# record through this before committing it, since duct samples the command line of every process
# a step starts, and some of those carry a token (git's remote helpers, curl's headers).
s#(://)[^/@[:space:]"'\\]+@#\1***@#g
s#(gh[pousr]_)[A-Za-z0-9]{20,}#\1***#g
s#(github_pat_)[A-Za-z0-9_]{20,}#\1***#g
s#([Bb]earer[[:space:]]+)[^[:space:]"'\\]+#\1***#g
s#([Aa]uthorization:[[:space:]]*([Tt]oken|[Bb]asic)[[:space:]]+)[^[:space:]"'\\]+#\1***#g
# DANDI API keys are plain hex, which GitHub's push protection does not recognise, so they are
# masked wherever they are assigned (shell, env listings, JSON); record.sh also masks the key
# of its own environment wherever it appears.
s#(DANDI_API_KEY["']?[[:space:]]*[=:][[:space:]]*["']?)[^[:space:]"'\\,}$]+#\1***#g
