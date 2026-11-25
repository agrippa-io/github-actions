#!/usr/bin/env bash
# Tests for publish.sh against a local stub API (python3 + jq + curl).
# shellcheck disable=SC2015 # `check && pass || fail`: pass only echoes, never fails
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../publish.sh"
WORK="$(mktemp -d)"
PORT="${PORT:-18737}"
LOG="$WORK/requests.log"
python3 "$HERE/stub_server.py" "$PORT" "$LOG" &
STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT" > /dev/null 2>&1 && break; sleep 0.1; done

cd "$WORK" || exit 1
echo '{"name":"@agrippa-io/node-demo","version":"1.2.3"}' > package.json
echo '{"openapi":"3.1.0","info":{"title":"Demo API","version":"0.9.0"},"paths":{}}' > openapi.json

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
run() { env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$WORK/out" DOCS_API_URL="http://127.0.0.1:$PORT/docs/v1/" "$@" "$SCRIPT" > "$WORK/stdout" 2> "$WORK/stderr"; }
output() { grep "^$1=" "$WORK/out" | tail -1 | cut -d= -f2-; }
last() { tail -1 "$LOG" | jq -r "$1"; }

: > "$WORK/out"
run DOCS_TOKEN=good-token DOCS_SPACE_KEY=platform DOCS_GIT_SHA=0123456789abcdef DOCS_REF_NAME=main \
  && [ "$(output outcome)" = created ] && [ "$(output version)" = 1.2.3 ] && [ "$(output status)" = 201 ] \
  && [ "$(last .path)" = /docs/v1/sources/node-demo/versions/1.2.3 ] \
  && [ "$(last '.body | [.kind, .name, .format, .docSpaceKey, .gitSha] | join(",")')" = "service,Demo API,openapi,platform,0123456789abcdef" ] \
  && pass "main: package name/version defaults, 201 created" || fail "main publish"

run DOCS_TOKEN=good-token DOCS_REF_NAME=main && [ "$(output outcome)" = unchanged ] \
  && pass "same content again: 200 unchanged succeeds" || fail "re-publish"

echo '{"openapi":"3.1.0","info":{"title":"Demo API","version":"0.9.0"},"paths":{"/x":{}}}' > openapi.json
if run DOCS_TOKEN=good-token DOCS_REF_NAME=main; then fail "409 should fail"; else grep -q "bump the version" "$WORK/stderr" && pass "changed content: 409 fails with a hint" || fail "409 message"; fi

run DOCS_TOKEN=good-token DOCS_REF_NAME=develop DOCS_GIT_SHA=abcdef0123456 && [ "$(output version)" = 1.2.3-dev.abcdef0 ] \
  && pass "develop: <version>-dev.<short sha>" || fail "develop version"

run DOCS_TOKEN_URL="http://127.0.0.1:$PORT/token" DOCS_CLIENT_ID=ci DOCS_CLIENT_SECRET=s DOCS_VERSION=2.0.0 DOCS_SOURCE_KEY=other DOCS_KIND=library DOCS_NAME=Other DOCS_SPACE_ID=11111111-1111-1111-1111-111111111111 \
  && [ "$(last .auth)" = "Bearer fetched-token" ] && [ "$(last '.body | [.kind, .name, .docSpaceId] | join(",")')" = "library,Other,11111111-1111-1111-1111-111111111111" ] \
  && [ "$(last '.body.gitSha // "none"')" = none ] \
  && pass "client-credentials token, explicit key/version/kind/name/space id" || fail "client credentials"

if run DOCS_TOKEN=bad DOCS_VERSION=3.0.0; then fail "401 should fail"; else grep -q "answered 401" "$WORK/stderr" && pass "401 fails" || fail "401 message"; fi
if run DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 DOCS_SOURCE_KEY=boom; then fail "500 should fail"; else pass "5xx fails"; fi
if run DOCS_VERSION=4.0.0; then fail "no token should fail"; else grep -q "token, or token-url" "$WORK/stderr" && pass "no token: clear error" || fail "no token message"; fi
if run DOCS_TOKEN=good-token DOCS_SPEC_PATH=missing.json; then fail "missing spec should fail"; else grep -q "spec not found" "$WORK/stderr" && pass "missing spec" || fail "missing spec message"; fi

requests=$(wc -l < "$LOG")
run DOCS_DRY_RUN=true DOCS_REF_NAME=main && [ "$(output outcome)" = dry-run ] && grep -q "PUT http://127.0.0.1:$PORT/docs/v1/sources/node-demo/versions/1.2.3" "$WORK/stdout" \
  && [ "$(wc -l < "$LOG")" = "$requests" ] && pass "dry run sends nothing" || fail "dry run"

rm package.json
if run DOCS_TOKEN=good-token; then fail "no key should fail"; else grep -q "source-key is required" "$WORK/stderr" && pass "no package.json: key required" || fail "key message"; fi
run DOCS_TOKEN=good-token DOCS_SOURCE_KEY=spec-only DOCS_REF_NAME=main && [ "$(output version)" = 0.9.0 ] \
  && pass "no package.json: version from info.version" || fail "info.version default"

echo
[ "$fails" -eq 0 ] && echo "publish-docs: all tests passed" || { echo "publish-docs: $fails failed"; exit 1; }
