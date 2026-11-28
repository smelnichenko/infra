#!/bin/sh
# clusters/production/cluster-config/etcd-backup.yaml's upload container, run as the CronJob runs it - its script from the
# manifest, in its image (.woodpecker/ci.yaml's etcd-backup-upload step; this checks the two images are the same), with a
# real rclone against a local remote standing in for the Pis' store:
#   passes  the snapshot uploaded, a 10-day-old backup pruned, a 1-day-old one kept
#   fails   a backup the prune cannot delete: the Job fails (exit 1, said) - after the snapshot is uploaded. `|| true` hid
#           it, so a bucket that stopped pruning grew unseen (the wave-patches review, 2026-11-28)
#
#   docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/repo:ro" -w /repo \
#     --entrypoint sh <the upload container's image> tests/etcd-backup-upload/run.sh
cd "$(dirname "$0")/../.." || exit 1
M=$PWD/clusters/production/cluster-config/etcd-backup.yaml
W=$(mktemp -d)
trap 'chmod -R u+w "$W" 2> /dev/null; rm -rf "$W"' EXIT
fails=0
# the upload container's script: the block under its `args: - |`, its indentation taken off (no yq in the image)
awk '/^ +- name: upload$/ { u = 1; next } u && /^ +args:$/ { a = 1; next } a && /^ +- \|$/ { s = 1; match($0, /^ */); ind = RLENGTH + 2; next }
     s { match($0, /^ */); if ($0 != "" && RLENGTH < ind) exit; print substr($0, ind + 1) }' "$M" > "$W/upload.sh"
grep -q 'rclone copyto /backup/etcd.db' "$W/upload.sh" || { echo "FAIL the upload script not found in $M"; exit 1; }
# the snapshot where the script reads it: /backup is the Job's volume, here a directory of the test's
sed -i "s#/backup/#$W/backup/#g" "$W/upload.sh"
# this image is the upload container's: the CI step's image as .woodpecker/ci.yaml names it, and the one this runs in
want=$(awk '/^ +- name: upload$/ { u = 1; next } u && /^ +image:/ { print $2; exit }' "$M")
step=$(awk '/^  - name: etcd-backup-upload$/ { s = 1; next } s && /^  - name:/ { exit } s && /^    image:/ { print $2; exit }' \
  .woodpecker/ci.yaml)
if [ "$step" != "$want" ]; then
  echo "FAIL the CI step's image ($step, .woodpecker/ci.yaml) is not the upload container's ($want)"; fails=$((fails + 1))
fi
if [ -n "${CI_STEP_IMAGE_CHECK:-}" ] && [ "$CI_STEP_IMAGE_CHECK" != "$want" ]; then
  echo "FAIL the CI step's image ($CI_STEP_IMAGE_CHECK) is not the upload container's ($want)"; fails=$((fails + 1))
fi
command -v rclone > /dev/null || { echo "FAIL no rclone here - run it in the upload container's image (above)"; exit 1; }
# the store: rclone's remote "pi" a local directory (the manifest's env names an s3 one; the type set here wins)
store() {
  chmod -R u+w "$W/s" 2> /dev/null; rm -rf "$W/s" "$W/backup"; mkdir -p "$W/s/etcd-backups" "$W/backup"
  echo "snapshot" > "$W/backup/etcd.db"
  echo old > "$W/s/etcd-backups/etcd-20200101-000000.db"; touch -d "@$(( $(date +%s) - 10 * 86400 ))" "$W/s/etcd-backups/etcd-20200101-000000.db"
  echo recent > "$W/s/etcd-backups/etcd-recent.db"; touch -d "@$(( $(date +%s) - 86400 ))" "$W/s/etcd-backups/etcd-recent.db"
}
run() { (cd "$W/s" && RCLONE_CONFIG="" RCLONE_CONFIG_PI_TYPE=local sh -e "$W/upload.sh") > "$W/out" 2>&1; echo $?; }
uploaded() { find "$W/s/etcd-backups" -maxdepth 1 -name 'etcd-2*.db' ! -name 'etcd-20200101-000000.db' | wc -l; }  # this run's
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1"; echo "    got:  $2"; echo "    want: $3"; sed 's/^/    | /' "$W/out"; fails=$((fails + 1)); fi; }

store
rc=$(run)
check "the snapshot uploaded, the 10-day-old backup pruned, the 1-day-old kept: exit 0, said OK" \
  "$rc $(uploaded) $([ -e "$W/s/etcd-backups/etcd-20200101-000000.db" ] && echo old-kept || echo old-gone) $([ -e "$W/s/etcd-backups/etcd-recent.db" ] && echo recent-kept) $(grep -c 'etcd-backup OK' "$W/out")" \
  "0 1 old-gone recent-kept 1"
# an old backup the prune cannot delete (its directory read-only): the prune fails, the Job with it - the snapshot in
store
mkdir "$W/s/etcd-backups/stuck"; mv "$W/s/etcd-backups/etcd-20200101-000000.db" "$W/s/etcd-backups/stuck/"; chmod a-w "$W/s/etcd-backups/stuck"
rc=$(run)
check "a prune that fails: exit 1, said, after the snapshot was uploaded - never OK" \
  "$rc $(grep -c 'pruning the 7-day-old backups FAILED' "$W/out") $(grep -c 'etcd-backup OK' "$W/out") $(find "$W/s/etcd-backups" -maxdepth 1 -name 'etcd-2*.db' | wc -l)" \
  "1 1 0 1"
echo "etcd-backup-upload: $([ $fails = 0 ] && echo ALL-PASS || echo "$fails FAILED")"
[ $fails = 0 ]
