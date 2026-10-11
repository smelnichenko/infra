#!/bin/sh
# Every Job and CronJob manifest under clusters/ carries velero.io/exclude-from-backup on its pod template: a Job's pod
# that ends while the weekly backup reads its volumes makes that backup PartiallyFailed (production, every week until
# 2026-10-11). The pod template read by indentation (template: / metadata: / labels:), as platform's
# chart-render-checks reads the charts.
set -eu
bad=0
seen=0
for f in $(find clusters -name '*.yaml' ! -name 'values*.yaml'); do
  got=$(awk '/^---/ {injob = 0; st = 0; next} /^ *$/ {next} {ind = match($0, /[^ ]/) - 1}
    /^kind: / {injob = 0} /^kind: (Job|CronJob) *$/ {jobs++; injob = 1}
    st && ind <= t {st = 0} st == 2 && ind <= t + 2 {st = 0} st == 3 && ind <= t + 4 {st = 0}
    /^ *template: *$/ {t = ind; st = 1; next}
    st == 1 && ind == t + 2 && /metadata: *$/ {st = 2; next}
    st == 2 && ind == t + 4 && /labels: *$/ {st = 3; next}
    st == 3 && ind == t + 6 && injob && /velero\.io\/exclude-from-backup: "true"/ {marks++; st = 0}
    END {print jobs + 0, marks + 0}' "$f")
  jobs=${got% *}
  marks=${got#* }
  seen=$((seen + jobs))
  if [ "$jobs" -gt "$marks" ]; then
    echo "FAIL: $f: $jobs Job/CronJob(s), $marks pod template(s) with velero.io/exclude-from-backup" >&2
    bad=1
  fi
done
# the weekly backup (every namespace) leaves Velero's own out: its maintenance Jobs' pods carry no label (Velero
# makes them), so only the namespace keeps them from failing it
awk '/^  full-weekly:/ {w=1; next} w && /^  [a-z]/ {w=0} w && /excludedNamespaces:/ {x=1; next}
  x && /^ *- *velero *$/ {ok=1} x && !/^ *- / {x=0} END {exit !ok}' clusters/production/velero/values.yaml \
  || { echo "FAIL: the full-weekly schedule does not exclude the velero namespace" >&2; bad=1; }
# a scan that reads nothing is no pass: the manifests hold two CronJobs (etcd-backup, the stale-PR sweeper) today
[ "$seen" -ge 2 ] || { echo "FAIL: the scan saw $seen Job/CronJob(s) under clusters/ - it reads nothing" >&2; bad=1; }
[ "$bad" = 0 ] && echo "velero exclude check: OK"
exit "$bad"
