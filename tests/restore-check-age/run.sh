#!/bin/sh
# clusters/production/cluster-config/restore-check-age.yaml's script, run as the CronJob runs it - the script from the
# manifest, its image's busybox sh and date - with rclone stubbed: what `rclone cat pi:restore-checks/<pi>/last-success`
# returns for each Pi decides.
#   passes  both fresh; one 59 h old (a turn retried late); one 30 min ahead of the clock
#   fails   either 61 h old (STALE, the other fine), either 2 h ahead, garbage, missing, the store unreachable (its own
#           error shown)
# Each Pi's last-report is shown whatever the verdict.
#
# In the CronJob's own image (.woodpecker/ci.yaml runs it there; this checks the two images are the same), no network:
#   docker run --rm --network none -v "$PWD:/repo:ro" -w /repo --entrypoint sh <the CronJob's image> \
#     tests/restore-check-age/run.sh
cd "$(dirname "$0")/../.." || exit 1
M=clusters/production/cluster-config/restore-check-age.yaml
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fails=0
# the script: the block under the container's `args: - |`, its indentation taken off (no yq in the image)
awk '/^ +args:$/ { a = 1; next } a && /^ +- \|$/ { s = 1; match($0, /^ */); ind = RLENGTH + 2; next }
     s { match($0, /^ */); if ($0 != "" && RLENGTH < ind) exit; print substr($0, ind + 1) }' "$M" > "$W/check.sh"
grep -q 'max_age_h=' "$W/check.sh" || { echo "FAIL the script not found in $M"; exit 1; }
# this image is the CronJob's: both name the same digest
want=$(sed -n 's/^ *image: //p' "$M")
image=$(sed -n 's/.*\(sha256:[0-9a-f]*\).*/\1/p' <<EOF_IMG
$want
EOF_IMG
)
if [ -n "${CI_STEP_IMAGE_CHECK:-}" ] && [ "$CI_STEP_IMAGE_CHECK" != "$want" ]; then
  echo "FAIL the CI step's image ($CI_STEP_IMAGE_CHECK) is not the CronJob's ($want)"; fails=$((fails + 1))
fi
[ -n "$image" ] || { echo "FAIL the CronJob's image is not pinned by digest: $want"; fails=$((fails + 1)); }
# the stub: last-success prints $PI1 / $PI2 and exits $RC (its error on stderr); last-report "REPORT <path>"
mkdir "$W/bin"
cat > "$W/bin/rclone" <<'STUB'
#!/bin/sh
[ "$1" = cat ] || exit 2
case "$2" in
  pi:restore-checks/pi1/last-success) [ -n "$PI1" ] && echo "$PI1" ;;
  pi:restore-checks/pi2/last-success) [ -n "$PI2" ] && echo "$PI2" ;;
  pi:restore-checks/*/last-report) echo "REPORT $2" ;;
  *) exit 3 ;;
esac
[ "${RC:-0}" = 0 ] || echo "Failed to cat: SignatureDoesNotMatch: the signature does not match" >&2
exit "${RC:-0}"
STUB
chmod 0755 "$W/bin/rclone"
case_() { # name, want (0 pass / 1 fail), pi1's last-success, pi2's, [rclone's exit], [output must contain]
  out=$(PI1="$3" PI2="$4" RC="${5:-0}" PATH="$W/bin:$PATH" sh -e "$W/check.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && { [ -z "${6:-}" ] || printf '%s\n' "$out" | grep -qF -- "$6"; }; then echo "PASS $1"
  else echo "FAIL $1 (rc $rc, want $2)"; printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1)); fi
}
at() { date -u -d "@$(( $(date -u +%s) + $1 ))" +%Y%m%dT%H%M%SZ; }
F=$(at -72000)
case_ "both fresh" 0 "$(at -7200)" "$F" 0 "both Pis restored within 60 h"
case_ "  each Pi's last report shown" 0 "$(at -7200)" "$F" 0 "REPORT pi:restore-checks/pi2/last-report"
case_ "pi1 59 h old (its turn retried late)" 0 "$(at -212400)" "$F"
case_ "pi1 61 h old (missed its turn), pi2 fresh" 1 "$(at -219600)" "$F" 0 "FAILED: pi1"
case_ "pi2 61 h old, pi1 fresh" 1 "$F" "$(at -219600)" 0 "FAILED: pi2"
case_ "30 min ahead of the clock" 0 "$(at 1800)" "$F"
case_ "2 h ahead of the clock" 1 "$F" "$(at 7200)" 0 "in the future"
case_ "garbage" 1 "not-a-time" "$F" 0 "missing or unreadable"
case_ "missing (rclone prints nothing)" 1 "$F" "" 0 "pi2's last-success missing or unreadable"
case_ "the store unreachable" 1 "" "" 1 "FAILED: pi1 pi2"
case_ "  the store's own error shown" 1 "" "" 1 "SignatureDoesNotMatch"
# "could not ask" is not "fresh": rclone failing after it printed a value
case_ "rclone fails after printing fresh values" 1 "$F" "$F" 1 "FAILED: pi1 pi2"
echo "restore-check-age: $([ $fails = 0 ] && echo ALL-PASS || echo "$fails FAILED")"
[ $fails = 0 ]
