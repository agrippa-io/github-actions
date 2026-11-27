#!/usr/bin/env bash
# Tests for trigger.sh against a local stub planner (python3 + jq + curl).
# shellcheck disable=SC2015 # `check && pass || fail`: pass only echoes, never fails
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../trigger.sh"
WORK="$(mktemp -d)"
PORT="${PORT:-18738}"
LOG="$WORK/requests.log"
python3 "$HERE/stub_server.py" "$PORT" "$LOG" &
STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT" > /dev/null 2>&1 && break; sleep 0.1; done

BASE="http://127.0.0.1:$PORT/cost-planner/v1"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
run() { : > "$WORK/out"; env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$WORK/out" GITHUB_REPOSITORY=agrippa-io/node-demo GITHUB_REF_NAME=develop GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_EVENT_NAME=push "$@" "$SCRIPT" > "$WORK/stdout" 2> "$WORK/stderr"; }
output() { grep "^$1=" "$WORK/out" | tail -1 | cut -d= -f2-; }
last() { tail -1 "$LOG" | jq -r "$1"; }
requests() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }

before=$(requests)
run && [ "$(output outcome)" = skipped ] && grep -q "skipped" "$WORK/stdout" && [ "$(requests)" = "$before" ] \
  && pass "no url, no token: skipped, exit 0, nothing sent" || fail "unconfigured"
run COST_PLANNER_URL="$BASE" && [ "$(output outcome)" = skipped ] && [ "$(requests)" = "$before" ] \
  && pass "url without token: skipped" || fail "url only"
run COST_PLANNER_TOKEN=good-token && [ "$(output outcome)" = skipped ] \
  && pass "token without url: skipped" || fail "token only"

run COST_PLANNER_URL="$BASE/" COST_PLANNER_TOKEN=good-token \
  && [ "$(output outcome)" = accepted ] && [ "$(output status)" = 202 ] && [ "$(output joined)" = false ] \
  && [ "$(last .path)" = /cost-planner/v1/webhooks/inventory-sync ] && [ "$(last .auth)" = "Bearer good-token" ] \
  && [ "$(last '.body | [.repo, .ref, .sha, .event] | join(",")')" = "agrippa-io/node-demo,develop,0123456789abcdef0123456789abcdef01234567,push" ] \
  && pass "202: queued, body from the GitHub context, trailing slash trimmed" || fail "accepted"

run COST_PLANNER_URL="$BASE" COST_PLANNER_TOKEN=good-token COST_REPO=agrippa-io/other COST_REF=main COST_SHA=not-a-sha COST_EVENT=workflow_dispatch \
  && [ "$(output joined)" = true ] && grep -q "joined" "$WORK/stdout" \
  && [ "$(last '.body | [.repo, .ref, (.sha // "none"), .event] | join(",")')" = "agrippa-io/other,main,none,workflow_dispatch" ] \
  && pass "explicit repo/ref/event, a non-hex sha left out, joined a running sync" || fail "explicit inputs"

run COST_PLANNER_URL="$BASE" COST_PLANNER_TOKEN=bad && [ "$(output outcome)" = failed ] && [ "$(output status)" = 401 ] && grep -q "::warning::.*401" "$WORK/stdout" \
  && pass "401: a warning, the build stays green" || fail "401 lenient"
if run COST_PLANNER_URL="$BASE" COST_PLANNER_TOKEN=bad COST_STRICT=true; then fail "401 strict should fail"; else grep -q "::error::.*401" "$WORK/stderr" && pass "401 strict: fails the step" || fail "401 strict message"; fi

run COST_PLANNER_URL="http://127.0.0.1:$PORT/unconfigured/v1" COST_PLANNER_TOKEN=good-token && grep -q "not configured (503" "$WORK/stdout" \
  && pass "503: planner trigger not configured, warning" || fail "503"
run COST_PLANNER_URL="http://127.0.0.1:$PORT/boom/v1" COST_PLANNER_TOKEN=good-token && grep -q "answered 500" "$WORK/stdout" \
  && pass "5xx: warning" || fail "500"
run COST_PLANNER_URL="http://127.0.0.1:1/v1" COST_PLANNER_TOKEN=good-token COST_TIMEOUT=3 && [ "$(output outcome)" = failed ] && grep -q "could not reach" "$WORK/stdout" \
  && pass "unreachable planner: warning, exit 0" || fail "unreachable"
if run COST_PLANNER_URL="http://127.0.0.1:1/v1" COST_PLANNER_TOKEN=good-token COST_TIMEOUT=3 COST_STRICT=true; then fail "unreachable strict should fail"; else pass "unreachable strict: fails"; fi

before=$(requests)
run COST_PLANNER_URL="$BASE" COST_PLANNER_TOKEN=good-token COST_DRY_RUN=true && [ "$(output outcome)" = dry-run ] \
  && grep -q "POST $BASE/webhooks/inventory-sync" "$WORK/stdout" && ! grep -v '^::add-mask::' "$WORK/stdout" | grep -q good-token && [ "$(requests)" = "$before" ] \
  && pass "dry run: prints the request without the token, sends nothing" || fail "dry run"

if run COST_PLANNER_URL=ftp://x COST_PLANNER_TOKEN=t; then fail "bad url should fail"; else grep -q "http(s) URL" "$WORK/stderr" && pass "a non-http url is an input error" || fail "bad url message"; fi
if run COST_STRICT=maybe; then fail "bad strict should fail"; else grep -q "strict must be" "$WORK/stderr" && pass "strict must be true or false" || fail "bad strict message"; fi

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
