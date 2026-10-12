#!/bin/sh
# Woodpecker's server and agent run one release (clusters/production/woodpecker/values.yaml): an agent of another
# version than its server is untested - the values file only said so in a comment. Reads both image tags.
set -eu
f=clusters/production/woodpecker/values.yaml
fail() { echo "woodpecker tags check: FAIL: $*" >&2; exit 1; }
tags() { awk '/^server:/ {s="server"} /^agent:/ {s="agent"} /^[a-z]/ && !/^(server|agent):/ {s=""} s && /^    tag: / {print s, $2}'; }
[ "$(tags < "$f" | wc -l)" = 2 ] || fail "not one server and one agent image tag in $f: $(tags < "$f" | tr '\n' ' ')"
server=$(tags < "$f" | awk '$1 == "server" {print $2}'); agent=$(tags < "$f" | awk '$1 == "agent" {print $2}')
[ -n "$server" ] && [ "$server" = "$agent" ] || fail "server $server, agent $agent - keep them on one release"
# the check itself: two different tags are refused
fx='server:\n  image:\n    tag: v1\nagent:\n  image:\n    tag: v2\n'
[ "$(printf "$fx" | tags | tr '\n' ' ')" = "server v1 agent v2 " ] || fail "the fixture's two tags not read apart"
echo "woodpecker tags check: OK (server and agent $server)"
