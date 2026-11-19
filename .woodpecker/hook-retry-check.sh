#!/bin/sh
# The apps whose charts carry sync hooks and the Vagrant copy runs (schnappy-data-envs, schnappy-apps-envs,
# schnappy-observability) retry a failed sync: auto-sync never retries a revision by itself, and a PostSync hook that failed
# left its app Synced with the hook not run (platform's hook-templates ConfigMap applied before it). Each one's
# syncPolicy holds retry - a sibling of automated, at its indentation (an ApplicationSet's template too) - with a limit
# of 1 or more and a backoff. Fails closed: a file missing or unread fails it.
fails=0
# (schnappy-sonarqube's retry waits: the copy runs no SonarQube - its change could not be proven there)
for app in schnappy-data-envs schnappy-apps-envs schnappy-observability; do
  f=clusters/production/argocd/apps/$app.yaml
  [ -r "$f" ] || { echo "FAIL $f not read"; fails=$((fails + 1)); continue; }
  got=$(awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*syncPolicy:[[:space:]]*$/ { sp = ind($0); insp = 1; next }
    insp && ind($0) <= sp { insp = 0; inr = 0 }
    insp && /^[[:space:]]*automated:/ { auto = ind($0) }
    insp && /^[[:space:]]*retry:[[:space:]]*$/ { r = ind($0); inr = 1; next }
    inr && ind($0) <= r { inr = 0 }
    inr && /^[[:space:]]*limit:[[:space:]]*[0-9]+/ && ind($0) == r + 2 { split($0, a, ":"); lim = a[2] + 0 }
    inr && /^[[:space:]]*backoff:/ && ind($0) == r + 2 { bo = 1 }
    END { printf "%s %s %s", (r != "" && r == auto) ? "sibling" : "misplaced", lim + 0, bo + 0 }' "$f")
  case "$got" in
    "sibling "[1-9]*" 1") echo "ok $app: retry $got" ;;
    *) echo "FAIL $app: syncPolicy.retry '$got' - a sibling of automated, a limit of 1 or more, a backoff"; fails=$((fails + 1)) ;;
  esac
done
[ "$fails" -eq 0 ] || exit 1
echo "hook apps retry: OK"
