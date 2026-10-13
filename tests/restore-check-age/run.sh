#!/bin/bash
# clusters/production/cluster-config/restore-check-age.yaml's script, run as the CronJob runs it - in its own image, as
# nobody, on a read-only root - with rclone stubbed: what `rclone cat pi:restore-checks/<pi>/last-success` returns for
# each Pi decides.
#   passes  both fresh; one 49 h old; one 30 min ahead of the clock
#   fails   either 51 h old (STALE, the other fine), either 2 h ahead, garbage, missing, the store unreachable
# Each Pi's last-report is shown whatever the verdict. Needs docker and python3 with PyYAML.
# Usage: bash tests/restore-check-age/run.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
M=clusters/production/cluster-config/restore-check-age.yaml
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
read -r image < <(python3 - "$M" "$W/check.sh" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
open(sys.argv[2], "w").write(c["args"][0])
print(c["image"])
PY
)
# the stub: `rclone cat pi:restore-checks/<pi>/last-success` prints $PI1 or $PI2 and exits $RC; last-report "REPORT <pi>"
cat > "$W/rclone" <<'STUB'
#!/bin/sh
[ "$1" = cat ] || exit 2
case "$2" in
  pi:restore-checks/pi1/last-success) [ -n "$PI1" ] && echo "$PI1" ;;
  pi:restore-checks/pi2/last-success) [ -n "$PI2" ] && echo "$PI2" ;;
  pi:restore-checks/*/last-report) echo "REPORT $2" ;;
  *) exit 3 ;;
esac
exit "${RC:-0}"
STUB
chmod 0755 "$W" "$W/rclone" "$W/check.sh"
fails=0
case_() { # name, want (0 pass / 1 fail), pi1's last-success, pi2's, [rclone's exit], [output must contain]
  out=$(docker run --rm -u 65534 --read-only --tmpfs /tmp -e PI1="$3" -e PI2="$4" -e RC="${5:-0}" \
    -v "$W:/t:ro" --entrypoint /bin/sh "$image" -c 'PATH=/t:$PATH; sh -e /t/check.sh' 2>&1); rc=$?
  if [ "$rc" = "$2" ] && { [ -z "${6:-}" ] || grep -qF -- "$6" <<< "$out"; }; then echo "PASS $1"
  else echo "FAIL $1 (rc $rc, want $2)"; sed 's/^/    /' <<< "$out"; fails=$((fails + 1)); fi
}
at() { date -u -d "$1" +%Y%m%dT%H%M%SZ; }
F=$(at '-20 hours')
case_ "both fresh" 0 "$(at '-2 hours')" "$F" 0 "both Pis restored within 50 h"
case_ "  each Pi's last report shown" 0 "$(at '-2 hours')" "$F" 0 "REPORT pi:restore-checks/pi2/last-report"
case_ "pi1 49 h old" 0 "$(at '-49 hours')" "$F"
case_ "pi1 51 h old (missed its turn), pi2 fresh" 1 "$(at '-51 hours')" "$F" 0 "FAILED: pi1"
case_ "pi2 51 h old, pi1 fresh" 1 "$F" "$(at '-51 hours')" 0 "FAILED: pi2"
case_ "30 min ahead of the clock" 0 "$(at '+30 minutes')" "$F"
case_ "2 h ahead of the clock" 1 "$F" "$(at '+2 hours')" 0 "in the future"
case_ "garbage" 1 "not-a-time" "$F" 0 "missing or unreadable"
case_ "missing (rclone prints nothing)" 1 "$F" "" 0 "pi2's last-success missing or unreadable"
case_ "the store unreachable" 1 "" "" 1 "FAILED: pi1 pi2"
echo "restore-check-age: $([ $fails = 0 ] && echo ALL-PASS || echo "$fails FAILED")"
[ $fails = 0 ]
