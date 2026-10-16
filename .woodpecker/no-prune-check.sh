#!/bin/sh
# No Argo CD application prunes: a prune is a cascade delete - on the root app every child Application, on a stateful
# app its StatefulSets and volumes (data gone). A resource dropped from git is deleted by hand. Automated prune and the
# Prune=true sync option both refused; prune: false is fine. Fails closed: a file unread (grep's 2) fails it too.
files=$(find clusters -type f \( -name '*.yaml' -o -name '*.yml' \))
[ -n "$files" ] || { echo "FAIL no manifests found under clusters/"; exit 1; }
# shellcheck disable=SC2086
found=$(grep -nE '^[^#]*(prune: *"?true"?|Prune=true)' $files); rc=$?
[ "$rc" -le 1 ] || { echo "FAIL the manifests not read (grep exit $rc)"; exit 1; }
if [ -n "$found" ]; then
  echo "FAIL an Argo CD prune is back:"
  printf '%s\n' "$found" | sed 's/^/  /'
  exit 1
fi
echo "PASS no Argo CD application prunes ($(printf '%s\n' "$files" | wc -l) manifests read)"
