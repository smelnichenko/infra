#!/usr/bin/env bash
# The stale PR environment sweeper (clusters/production/argocd/extras/stale-pr-envs-cronjob.yaml) run as its CronJob
# runs it - the script from the manifest, its image's busybox sh, the manifest's environment and CA mount - against
# stub kubectl and curl: which Applications it prunes, which Vault keys it purges, and that every failure fails the
# run instead of passing as "nothing to do".
#
# In the CronJob's own image (.woodpecker/ci.yaml runs it there; this checks the two images are the same), no network:
#   docker run --rm --network none -v "$PWD:/repo:ro" -w /repo --entrypoint bash <the CronJob's image> \
#     tests/stale-pr-envs-sweeper/run.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
M=clusters/production/argocd/extras/stale-pr-envs-cronjob.yaml
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fails=0
check() {  # check <what> <got> <want>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}
cj() { yq "select(.kind == \"CronJob\") | $1" "$M"; }
pod='.spec.jobTemplate.spec.template.spec'
cj "$pod.containers[0].command[2]" > "$W/script.sh"
env_of() { cj "$pod.containers[0].env[] | select(.name == \"$1\") | .value"; }
FORGEJO_API=$(env_of FORGEJO_API) VAULT_ADDR=$(env_of VAULT_ADDR)
STALE_DAYS=$(env_of STALE_DAYS) CLOSED_GRACE_HOURS=$(env_of CLOSED_GRACE_HOURS)
# Vault's CA as the pod has it: the Secret vault-pi-ca's ca.crt where the container mounts it
ca_vol=$(cj "$pod.volumes[] | select(.secret.secretName == \"vault-pi-ca\") | .name")
CA_PATH=$(cj "$pod.containers[0].volumeMounts[] | select(.name == \"${ca_vol:-none}\") | .mountPath")/ca.crt

mkdir -p "$W/bin"
# Argo CD: the preview Applications in $W/apps.json, less the ones deleted; LIST_FAILS_AT=n fails the n-th listing
cat > "$W/bin/kubectl" <<'STUB_KUBECTL'
#!/bin/bash
echo "kubectl $*" >> "$W/kubectl-calls"
case "$*" in
  "get application -n argocd -l preview-env=true -o "*)
    n=$(( $(cat "$W/lists" 2> /dev/null || echo 0) + 1 )); echo $n > "$W/lists"
    [ "${LIST_FAILS_AT:-0}" != "$n" ] || { echo "error: the server is currently unable to handle the request" >&2; exit 1; }
    json=$(jq --rawfile d "$W/deleted" '.items |= map(select(.metadata.name as $n | ($d | split("\n") | index($n)) | not))' \
      "$W/apps.json")
    case "$*" in
      *" -o json") echo "$json" ;;
      *" -o jsonpath={.items[*].metadata.labels.pr-number}") echo "$json" | jq -r '[.items[].metadata.labels."pr-number"] | join(" ")' ;;
      *) echo "kubectl stub: unexpected output $*" >&2; exit 1 ;;
    esac ;;
  "delete application -n argocd "*)
    [ -z "${DELETE_FAILS:-}" ] || { echo "error: the server is currently unable to handle the request" >&2; exit 1; }
    echo "$5" >> "$W/deleted" ;;
  *) echo "kubectl stub: unexpected call $*" >&2; exit 1 ;;
esac
STUB_KUBECTL
# Forgejo: an issue from $W/forgejo/<repo>-<pr>.json; Vault: keys as files under $W/vault, verified only against the
# pod's CA (anything else: curl's own TLS failure), the token taken from a header; every argv recorded
cat > "$W/bin/curl" <<'STUB_CURL'
#!/bin/bash
printf '%s\n' "$*" >> "$W/curl-argv"
method=GET out="" fmt="" fail="" insecure="" cacert="" url="" headers=()
while [ $# -gt 0 ]; do
  case $1 in
    -X|--request) method=$2; shift ;;
    -o|--output) out=$2; shift ;;
    -w|--write-out) fmt=$2; shift ;;
    -H|--header) if [ "$2" = @- ]; then while IFS= read -r l; do headers+=("$l"); done; else headers+=("$2"); fi; shift ;;
    --cacert) cacert=$2; shift ;;
    --connect-timeout|--max-time|-m) shift ;;
    -k|--insecure) insecure=1 ;;
    -f|--fail) fail=1 ;;
    -s|-S|--silent|--show-error) ;;
    --*) echo "curl stub: unknown option $1" >&2; exit 2 ;;
    -?*) for ((i = 1; i < ${#1}; i++)); do
           case ${1:i:1} in f) fail=1 ;; k) insecure=1 ;; s|S) ;; *) echo "curl stub: unknown flag in $1" >&2; exit 2 ;; esac
         done ;;
    *) url=$1 ;;
  esac
  shift
done
header() { local h; for h in "${headers[@]}"; do case $h in "$1: "*) printf '%s' "${h#"$1: "}"; return ;; esac; done; }
answer() {  # answer <code> <body>: as curl gives it - -f fails on >= 400 with no body; -o writes it; -w the code
  if [ -n "$fail" ] && [ "$1" -ge 400 ]; then
    echo "curl: (22) The requested URL returned error: $1" >&2; [ -z "$fmt" ] || printf '%s' "${fmt//"%{http_code}"/$1}"; exit 22
  fi
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  [ -z "$fmt" ] || printf '%s' "${fmt//"%{http_code}"/$1}"
  exit 0
}
unreached() { echo "curl: ($1) $2" >&2; [ -z "$fmt" ] || printf 000; exit "$1"; }
case $url in
  "$FORGEJO_API"/repos/schnappy/*/issues/*)
    [ -z "${FORGEJO_DOWN:-}" ] || unreached 7 "Failed to connect to git.pmon.dev port 443 after 3 ms: Could not connect to server"
    [ "$(header Authorization)" = "token $FORGEJO_TOKEN" ] || answer 401 '{"message":"token is required"}'
    r=${url#"$FORGEJO_API"/repos/schnappy/}
    f="$W/forgejo/${r%%/*}-${r##*/}.json"
    [ -f "$f" ] || answer 404 '{"message":"The target couldn'"'"'t be found."}'
    answer 200 "$(cat "$f")" ;;
  "$VAULT_ADDR"/v1/*)
    if [ -n "$insecure" ]; then echo "$method $url" >> "$W/insecure"
    elif [ "$cacert" != "$CA_PATH" ]; then
      unreached 60 "SSL certificate problem: self-signed certificate in certificate chain"
    fi
    [ -z "${VAULT_DOWN:-}" ] || unreached 7 "Failed to connect to 192.168.11.5 port 8200 after 3 ms: Could not connect to server"
    p=${url#"$VAULT_ADDR"/v1/}
    echo "$method $p" >> "$W/vault-calls"
    [ "$(header X-Vault-Token)" = "$VAULT_TOKEN_GOOD" ] \
      || answer 403 '{"errors":["2 errors occurred:\n\t* permission denied\n\t* invalid token\n\n"]}'
    case "$method $p" in
      "POST auth/token/renew-self") touch "$W/renewed"; answer 200 '{"auth":{"lease_duration":2592000,"renewable":true}}' ;;
      "LIST secret/metadata/"*)
        [ "${VAULT_LIST_FAILS:-}" != "$p" ] || answer 500 '{"errors":["internal error"]}'
        [ "${VAULT_LIST_GARBAGE:-}" != "$p" ] || answer 200 '<html>a proxy answered</html>'
        d=${p#secret/metadata/}; d=${d%/}; dir="$W/vault${d:+/$d}"
        [ -d "$dir" ] && [ -n "$(ls -A "$dir")" ] || answer 404 '{"errors":[]}'
        answer 200 "$(cd "$dir" && for e in *; do if [ -d "$e" ]; then echo "$e/"; else echo "$e"; fi; done \
          | jq -Rsc '{data: {keys: (split("\n") | map(select(length > 0)))}}')" ;;
      "DELETE secret/metadata/"*)
        [ -z "${VAULT_DELETE_FAILS:-}" ] || answer 503 '{"errors":["Vault is sealed"]}'
        k=${p#secret/metadata/}
        # a key and every version of it; a folder's path deletes nothing (Vault answers 204 all the same)
        if [ -f "$W/vault/$k" ]; then
          rm "$W/vault/$k"; echo "$k" >> "$W/purged"
          d=$(dirname "$W/vault/$k")
          while [ "$d" != "$W/vault" ] && rmdir "$d" 2> /dev/null; do d=$(dirname "$d"); done
        fi
        answer 204 '' ;;
      *) answer 405 '{"errors":["1 error occurred:\n\t* unsupported operation\n\n"]}' ;;
    esac ;;
  *) echo "curl stub: unexpected URL $url" >&2; exit 6 ;;
esac
STUB_CURL
chmod +x "$W/bin/kubectl" "$W/bin/curl"

now=$(date +%s)
at() {  # at <seconds ago> [<offset +HH:MM | -HH:MM>]: that time in RFC 3339, in UTC ("Z") or at that offset
  local t=$((now - $1)) o=${2:-Z} s
  [ "$o" = Z ] && { date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ; return; }
  s=$(( ${o:0:1}1 * (10#${o:1:2} * 3600 + 10#${o:4:2} * 60) ))
  echo "$(date -u -d "@$((t + s))" +%Y-%m-%dT%H:%M:%S)$o"
}
apps() {  # apps <name> <pr> <repo> <deployedAt|""> <creationTimestamp> ...: the preview Applications Argo CD lists
  local items=()
  while [ $# -gt 0 ]; do
    items+=("$(jq -nc --arg n "$1" --arg p "$2" --arg r "$3" --arg d "$4" --arg c "$5" '{metadata: {name: $n,
      creationTimestamp: $c, labels: {"preview-env": "true", "pr-number": $p, "source-repo": $r}},
      status: (if $d == "" then {} else {history: [{deployedAt: $d}]} end)}')")
    shift 5
  done
  printf '%s\n' "${items[@]}" | jq -sc '{items: map(select(. != null))}' > "$W/apps.json"
}
issue() {  # issue <repo> <pr> <state> [<closed_at>]
  mkdir -p "$W/forgejo"
  jq -nc --arg s "$3" --arg c "${4:-}" '{state: $s, closed_at: (if $c == "" then null else $c end)}' > "$W/forgejo/$1-$2.json"
}
keys() {  # keys <path>...: Vault's secret/ mount holds these keys (and nothing else)
  rm -rf "$W/vault"; mkdir -p "$W/vault"
  local k; for k in "$@"; do mkdir -p "$(dirname "$W/vault/$k")"; echo x > "$W/vault/$k"; done
}
run() {  # run <env>...: the script as the CronJob runs it; its exit in $rc, its output in $out
  rm -rf "$W/tmp"; mkdir "$W/tmp"; : > "$W/deleted"
  rm -f "$W"/{kubectl-calls,curl-argv,lists,purged,vault-calls,insecure,renewed}
  out=$(cd "$W/tmp" && env -i PATH="$W/bin:/usr/local/bin:/usr/bin:/bin" HOME="$W/tmp" TMPDIR="$W/tmp" W="$W" \
    CA_PATH="$CA_PATH" FORGEJO_API="$FORGEJO_API" VAULT_ADDR="$VAULT_ADDR" STALE_DAYS="$STALE_DAYS" \
    CLOSED_GRACE_HOURS="$CLOSED_GRACE_HOURS" FORGEJO_TOKEN=forgejo-secret-123 VAULT_TOKEN=vault-secret-456 \
    VAULT_TOKEN_GOOD=vault-secret-456 "$@" sh "$W/script.sh" 2>&1); rc=$?
}
deleted() { paste -sd, "$W/deleted"; }
purged() { sort "$W/purged" 2> /dev/null | paste -sd,; }
said() { grep -c -- "$1" <<< "$out"; }

h=3600 d=86400
keys

# ── 1. Argo CD: which preview Applications go
apps schnappy-pr-5 5 monitor "$(at $h)" "$(at $h)"
issue monitor 5 open
run
check "a preview app deployed an hour ago, its PR open: kept (Argo CD's RFC 3339 time read - busybox date reads none)" \
  "$rc $(deleted)" "0 "
apps schnappy-pr-5 5 monitor "$(at $((8 * d)))" "$(at $((9 * d)))"
run
check "deployed 8 days ago (> STALE_DAYS): pruned" "$rc $(deleted)" "0 schnappy-pr-5"
apps schnappy-pr-5 5 monitor "" "$(at $((8 * d)))"
run
check "never deployed, created 8 days ago: pruned (its creation the age)" "$rc $(deleted)" "0 schnappy-pr-5"
apps schnappy-pr-5 5 monitor "" "$(at $h)"
run
check "never deployed, created an hour ago: kept" "$rc $(deleted)" "0 "
# Forgejo's closed_at carries the server's offset: read without it, 25 h ago at +03:00 is 22 h, 23 h ago at -03:00 26 h
apps schnappy-pr-5 5 monitor "$(at $h)" "$(at $h)"
issue monitor 5 closed "$(at $((25 * h)) +03:00)"
run
check "its PR closed 25 h ago (> CLOSED_GRACE_HOURS, at +03:00): pruned" "$rc $(deleted)" "0 schnappy-pr-5"
issue monitor 5 closed "$(at $((23 * h)) -03:00)"
run
check "its PR closed 23 h ago (at -03:00): kept" "$rc $(deleted)" "0 "
issue monitor 5 open
apps schnappy-pr-5 5 monitor "$(at $h)" "$(at $h)" schnappy-pr-6 6 chat "$(at $((8 * d)))" "$(at $((8 * d)))"
issue chat 6 open
run FORGEJO_DOWN=1
check "Forgejo unanswered: every app left, the run fails, each said" \
  "$rc $(deleted) $(said 'not read from Forgejo')" "1  2"
apps schnappy-pr-5 5 monitor "yesterday" "$(at $((8 * d)))" schnappy-pr-6 6 chat "$(at $((8 * d)))" "$(at $((8 * d)))"
run
check "a deploy time it cannot read: that app left, said, the run fails - the others still swept" \
  "$rc $(deleted) $(said 'schnappy-pr-5: its deploy time unreadable')" "1 schnappy-pr-6 1"
apps schnappy-pr-5 5 monitor "$(at $((8 * d)))" "$(at $((8 * d)))"
# an app on its way out (Argo CD deleting it): not deleted again; one with no PR number: not the sweeper's
apps schnappy-pr-5 5 monitor "$(at $((8 * d)))" "$(at $((8 * d)))" other 7 monitor "$(at $((8 * d)))" "$(at $((8 * d)))"
jq '.items[0].metadata.deletionTimestamp = "2026-10-09T06:00:00Z" | del(.items[1].metadata.labels."pr-number")' \
  "$W/apps.json" > "$W/apps.next" && mv "$W/apps.next" "$W/apps.json"
run
check "an app being deleted already, one with no PR number: neither touched, the run passes" "$rc $(deleted)" "0 "
apps schnappy-pr-5 5 monitor "$(at $h)" "$(at $h)"
issue monitor 5 closed "never"
run
check "its PR closed at a time it cannot read: left, said, the run fails" \
  "$rc $(deleted) $(said 'closed at a time unreadable')" "1  1"
issue monitor 5 open
run FORGEJO_DOWN=1 VAULT_TOKEN=
check "an app left (Forgejo unanswered) and no Vault token: the run still fails" "$rc" 1
apps schnappy-pr-5 5 monitor "$(at $((8 * d)))" "$(at $((8 * d)))"
run LIST_FAILS_AT=1
check "the Applications not listed: the run fails, nothing pruned, Vault not touched" \
  "$rc $(deleted) $(cat "$W/vault-calls" 2> /dev/null | wc -l)" "1  0"
run DELETE_FAILS=1
check "a prune that fails: the run fails" "$rc" 1
check "no token on any argv (Forgejo's)" "$(grep -c 'forgejo-secret-123' "$W/curl-argv")" 0

# ── 2. Vault: which preview secrets go
apps schnappy-pr-5 5 monitor "$(at $h)" "$(at $h)" schnappy-pr-8 8 monitor "$(at $((8 * d)))" "$(at $((8 * d)))"
issue monitor 8 open
keys schnappy-pr-5/app schnappy-pr-6/a schnappy-pr-6/b schnappy-pr-7/sub/c schnappy-pr-8/k schnappy-pr-x/keep \
  schnappy/keep schnappy-infra/keep argocd/vault-cleanup-token
run
check "the run passes" "$rc" 0
check "renewed first (a periodic token lives while renewed), then listed" "$(head -2 "$W/vault-calls" 2> /dev/null | paste -sd,)" \
  "POST auth/token/renew-self,LIST secret/metadata/"
check "every key of each preview prefix with no live app purged (a folder's too, the just-pruned app's too); the live \
one's, a non-preview prefix's and the other paths kept" "$(purged)" \
  "schnappy-pr-6/a,schnappy-pr-6/b,schnappy-pr-7/sub/c,schnappy-pr-8/k"
check "Vault verified against the pod's CA ($CA_PATH) on every call, never -k" \
  "$(grep -c "$VAULT_ADDR" "$W/curl-argv") $(grep "$VAULT_ADDR" "$W/curl-argv" | grep -c -- "--cacert $CA_PATH ") \
$(cat "$W/insecure" 2> /dev/null | wc -l)" "$(grep -c "$VAULT_ADDR" "$W/curl-argv") $(grep -c "$VAULT_ADDR" "$W/curl-argv") 0"
check "no token on any argv (Vault's, Forgejo's)" "$(grep -c 'vault-secret-456\|forgejo-secret-123' "$W/curl-argv")" 0
keys schnappy-pr-6/a
apps
run VAULT_TOKEN=
check "no token (its Secret absent): Vault skipped, said, the run passes" \
  "$rc $(cat "$W/vault-calls" 2> /dev/null | wc -l) $(said 'VAULT_TOKEN not set')" "0 0 1"
run VAULT_TOKEN=hvs.dead
check "a dead token: the run fails, said, nothing purged" "$rc $(said 'invalid token') $(purged)" "1 1 "
run VAULT_DOWN=1
check "Vault unanswered: the run fails, said" "$rc $(said 'auth/token/renew-self: no answer')" "1 1"
run VAULT_LIST_FAILS=secret/metadata/
check "Vault's listing refused: the run fails, said, nothing purged" \
  "$rc $(said 'LIST secret/metadata/: 500') $(purged)" "1 1 "
run VAULT_LIST_GARBAGE=secret/metadata/
check "Vault's listing answered with no JSON (a proxy's page): the run fails (jq's own exit), nothing purged" \
  "$([ "$rc" -ne 0 ] && echo failed || echo passed) $(purged)" "failed "
apps schnappy-pr-6 6 monitor "$(at $h)" "$(at $h)"
issue monitor 6 open
run LIST_FAILS_AT=2
check "the live apps not listed (after the prune): the run fails, nothing purged - never every preview's secrets" \
  "$rc $(purged)" "1 "
apps
run VAULT_DELETE_FAILS=1
check "a purge that fails: the run fails, said" "$rc $(said 'DELETE secret/metadata/schnappy-pr-6/a: 503')" "1 1"
keys schnappy/keep
mkdir "$W/vault/schnappy-pr-9"
run
check "a preview prefix with nothing under it (Vault's 404): nothing to purge, the run passes" "$rc $(purged)" "0 "

# ── the manifest: what the script relies on
check "Vault's CA: the Secret vault-pi-ca (not optional), mounted read-only" \
  "$(cj "$pod.volumes[] | select(.name == \"${ca_vol:-none}\") | .secret.optional // false") \
$(cj "$pod.containers[0].volumeMounts[] | select(.name == \"${ca_vol:-none}\") | .readOnly")" "false true"
check "a Job that cannot start (its CA Secret missing) ends Failed: a deadline" \
  "$(cj '.spec.jobTemplate.spec.activeDeadlineSeconds // 0' | awk '{print ($1 > 0)}')" 1
check "CI runs this in the CronJob's own image" \
  "$(yq '.steps[] | select(.name == "stale-pr-envs-sweeper") | .image' .woodpecker/ci.yaml)" "$(cj "$pod.containers[0].image")"

[ "$fails" = 0 ] && echo "stale-pr-envs-sweeper: ALL-PASS" || { echo "stale-pr-envs-sweeper: $fails FAILED"; exit 1; }
