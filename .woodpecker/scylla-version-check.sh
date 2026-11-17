#!/bin/sh
# ScyllaDB's version, said twice in each data environment's values: scyllaOperator.version (the ScyllaCluster's - the
# version the cluster runs) and scylla.image (the schema Job's cqlsh, the cluster's own version). Renovate moved the image
# alone - the version had no annotation - so a "ScyllaDB release line" unit changed no ScyllaDB (2026-11-17's review).
# Both read here: equal, and the version annotated for Renovate (the same depName as the image), so one unit moves both.
set -eu
fail() { echo "scylla version check: FAIL: $*" >&2; exit 1; }
# image <file>: scylla.image's tag; version <file>: scyllaOperator.version; annotated <file>: the renovate line above it
image() { awk '/^[a-zA-Z]/ {s = ($0 ~ /^scylla:/)} s && /^  image: / {sub(/^  image: */, ""); sub(/^.*:/, ""); gsub(/"/, ""); print}' "$1"; }
version() { awk '/^[a-zA-Z]/ {s = ($0 ~ /^scyllaOperator:/)} s && /^  version: / {sub(/^  version: */, ""); gsub(/"/, ""); print}' "$1"; }
annotated() {
  awk '/^[a-zA-Z]/ {s = ($0 ~ /^scyllaOperator:/)} s && /^  version: / {print prev} {prev = $0}' "$1" \
    | grep -Eq '^ *# renovate: datasource=docker depName=scylladb/scylla *$'
}
check() {
  i=$(image "$1"); v=$(version "$1")
  [ -n "$i" ] && [ -n "$v" ] || fail "$1: scylla.image's tag '$i' or scyllaOperator.version '$v' not read"
  [ "$i" = "$v" ] || fail "$1: scylla.image $i, scyllaOperator.version $v - one version, both lines (Renovate moves them in one unit)"
  annotated "$1" || fail "$1: scyllaOperator.version without '# renovate: datasource=docker depName=scylladb/scylla' above it - Renovate never moves it"
  echo "scylla version check: OK ($1: $v)"
}
for f in clusters/production/schnappy-production-data/values.yaml clusters/production/schnappy-test-data/values.yaml; do
  check "$f"
done
# the check itself: two versions apart, and a version with no annotation, are refused
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'scylla:\n  image: scylladb/scylla:2026.2.10\nscyllaOperator:\n  # renovate: datasource=docker depName=scylladb/scylla\n  version: "2026.1.15"\n' > "$t/apart.yaml"
printf 'scylla:\n  image: scylladb/scylla:2026.1.15\nscyllaOperator:\n  version: "2026.1.15"\n' > "$t/bare.yaml"
for f in apart bare; do
  if (check "$t/$f.yaml") > /dev/null 2>&1; then fail "the fixture $f passed - the check would let it through"; fi
done
echo "scylla version check: OK (the check refuses versions apart and a version Renovate cannot see)"
