#!/bin/sh
# Each environment's mesh exceptions as platform's schnappy-mesh needs them (plan 123): the observability stack's
# PeerAuthentication exceptions (Alertmanager 9093, s3gw 9000 - plaintext from the sidecar-less Prometheus, Mimir and
# Tempo) on in schnappy-infra, where that stack runs - dropped there, alerts go silent (2026-04-20) - and said off in
# production and test; CNPG's 8000 exception off in schnappy-infra (its CNPG clusters run without a sidecar), on where
# the CNPG cluster carries one. The chart's defaults are both on: a key left out is "on". Read by indentation (this
# image has no Python), the peerAuthentication block's own keys only.
set -eu
key() {  # key <file> <peerAuthentication key>: its value, "" when absent
  awk -v k="$2" '/^[^ #]/ { inpa = ($0 ~ /^peerAuthentication: *$/) } inpa && $1 == k":" { print $2; exit }' "$1"
}
bad=0
check() {  # check <env> <key> <want: on|off>
  f=clusters/production/schnappy-$1-mesh/values.yaml
  [ -f "$f" ] || { echo "FAIL $f missing"; bad=1; return; }
  v=$(key "$f" "$2")
  case "$v" in false) got=off ;; ""|true) got=on ;; *) echo "FAIL $f peerAuthentication.$2: '$v' (true or false)"; bad=1; return ;; esac
  if [ "$got" = "$3" ]; then echo "ok   $1 peerAuthentication.$2 $got"; else echo "FAIL $1 peerAuthentication.$2 $got, want $3"; bad=1; fi
}
check infra observability on
check infra cnpgPostgres off
check production observability off
check production cnpgPostgres on
check test observability off
check test cnpgPostgres on
[ "$bad" = 0 ] && echo "mesh values: OK" || { echo "mesh values: FAILED"; exit 1; }
