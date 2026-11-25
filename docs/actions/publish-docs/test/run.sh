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
# run_args ENV=… -- flags…: the same, with command-line flags after the --.
run_args() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$WORK/out" DOCS_API_URL="http://127.0.0.1:$PORT/docs/v1/" "${envs[@]}" "$SCRIPT" "$@" > "$WORK/stdout" 2> "$WORK/stderr"
}
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

# GraphQL (docs-platform-0 5.5): an SDL file, or introspection of a local URL.
cp "$HERE/fixtures/schema.graphql" schema.graphql
run_args DOCS_TOKEN=good-token DOCS_SOURCE_KEY=gql-sdl DOCS_REF_NAME=main -- --graphql schema.graphql \
  && [ "$(output outcome)" = created ] && [ "$(output version)" = 1.2.3 ] \
  && [ "$(last '.body | [.format, .name] | join(",")')" = "graphql,gql-sdl" ] \
  && [ "$(last '.doc.keys | join(",")')" = sdl ] \
  && [ "$(last '.doc.sdlHead')" = '"""A small schema for the publish-docs tests."""' ] \
  && pass "--graphql schema.graphql: format graphql, { sdl }, name defaults to the key" || fail "--graphql sdl"

run_args DOCS_TOKEN=good-token DOCS_SOURCE_KEY=gql-sdl DOCS_REF_NAME=main -- --graphql=schema.graphql && [ "$(output outcome)" = unchanged ] \
  && pass "--graphql=file form, same SDL again: unchanged" || fail "--graphql= form"

run DOCS_TOKEN=good-token DOCS_SOURCE_KEY=gql-env DOCS_VERSION=1.0.0 DOCS_GRAPHQL=schema.graphql DOCS_GRAPHQL_ENDPOINT=/docs/v1/graphql DOCS_NAME="Docs GraphQL" \
  && [ "$(last '.doc.keys | join(",")')" = "endpoint,sdl" ] && [ "$(last .doc.endpoint)" = /docs/v1/graphql ] \
  && [ "$(last .body.name)" = "Docs GraphQL" ] \
  && pass "graphql + graphql-endpoint inputs (env): endpoint rides along" || fail "graphql env inputs"

run_args DOCS_TOKEN=good-token DOCS_SOURCE_KEY=gql-url DOCS_VERSION=1.0.0 -- --graphql-url "http://localhost:$PORT/api/graphql?x=1" \
  && [ "$(last .body.format)" = graphql ] && [ "$(last '.doc.keys | join(",")')" = "__schema,endpoint" ] \
  && [ "$(last .doc.queryType)" = Query ] && [ "$(last .doc.endpoint)" = /api/graphql ] \
  && [ "$(tail -2 "$LOG" | head -1 | jq -r '.graphql.operationName')" = IntrospectionQuery ] \
  && grep -q "introspected http://localhost:$PORT/api/graphql" "$WORK/stdout" \
  && pass "--graphql-url localhost: introspects, sends { __schema, endpoint = URL path }" || fail "--graphql-url"

run DOCS_TOKEN=good-token DOCS_SOURCE_KEY=gql-url2 DOCS_VERSION=1.0.0 DOCS_GRAPHQL_URL="http://127.0.0.1:$PORT/graphql" DOCS_GRAPHQL_ENDPOINT=/v1/graphql \
  && [ "$(last .doc.endpoint)" = /v1/graphql ] && pass "graphql-url (env) with an explicit endpoint" || fail "graphql-url env"

requests=$(wc -l < "$LOG")
run_args DOCS_SOURCE_KEY=gql-dry DOCS_VERSION=1.0.0 -- --graphql-url "http://LOCALHOST:$PORT/graphql" --dry-run \
  && [ "$(output outcome)" = dry-run ] && grep -q '"format": "graphql"' "$WORK/stdout" \
  && [ "$(tail -1 "$LOG" | jq -r .graphql.operationName)" = IntrospectionQuery ] && [ "$(wc -l < "$LOG")" -eq $((requests + 1)) ] \
  && pass "--dry-run with --graphql-url: introspects, publishes nothing" || fail "graphql dry run"

for url in "http://[::1]:1/graphql" "http://docs.localhost:1/graphql" "http://127.0.0.2:1/graphql" "http://host.docker.internal:1/graphql"; do
  run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql-url "$url"
  grep -q "local environment" "$WORK/stderr" && fail "local $url refused" || pass "local graphql-url accepted: $url"
done

for url in "https://api.example.com/graphql" "http://10.0.0.5:4000/graphql" "http://localhost.example.com/graphql" "http://user@evil.com/graphql" "http://evil.com#@localhost/graphql" "http://evil.com?@localhost/" "http://localhost@evil.com/"; do
  if run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql-url "$url"; then fail "non-local $url should fail"; else grep -q "local environment" "$WORK/stderr" && pass "non-local graphql-url refused: $url" || fail "non-local message: $url"; fi
done
if run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql-url "ftp://localhost/graphql"; then fail "ftp should fail"; else grep -q "http(s) URL" "$WORK/stderr" && pass "graphql-url must be http(s)" || fail "scheme message"; fi
if run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql-url "http://localhost:$PORT/graphql-errors"; then fail "errors should fail"; else grep -q "introspection is disabled" "$WORK/stderr" && grep -q "no data.__schema" "$WORK/stderr" && pass "introspection errors: shown, step fails" || fail "introspection errors"; fi
if run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql-url "http://localhost:$PORT/graphql-down"; then fail "503 should fail"; else grep -q "answered 503" "$WORK/stderr" && pass "introspection 503 fails" || fail "introspection 503"; fi
if run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql-url "http://localhost:1/graphql"; then fail "unreachable should fail"; else grep -q "introspection request to" "$WORK/stderr" && pass "unreachable introspection URL fails" || fail "unreachable message"; fi
if run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql schema.graphql --graphql-url "http://localhost:$PORT/graphql"; then fail "both should fail"; else grep -q "not both" "$WORK/stderr" && pass "graphql and graphql-url together refused" || fail "both message"; fi
if run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql missing.graphql; then fail "missing sdl should fail"; else grep -q "GraphQL schema not found" "$WORK/stderr" && pass "missing SDL file" || fail "missing sdl message"; fi
printf '  \n\n' > empty.graphql
if run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql empty.graphql; then fail "empty sdl should fail"; else grep -q "GraphQL schema is empty" "$WORK/stderr" && pass "empty SDL file" || fail "empty sdl message"; fi
if run DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 DOCS_FORMAT=graphql; then fail "graphql with no schema should fail"; else grep -q "needs graphql" "$WORK/stderr" && pass "format graphql without a schema" || fail "no schema message"; fi
if run DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 DOCS_FORMAT=asyncapi DOCS_GRAPHQL=schema.graphql; then fail "asyncapi+graphql should fail"; else grep -q "does not take a GraphQL schema" "$WORK/stderr" && pass "another format with a GraphQL schema refused" || fail "format clash message"; fi
if run_args DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 -- --graphql schema.graphql --graphql-endpoint graphql; then fail "relative endpoint should fail"; else grep -q "must be a path" "$WORK/stderr" && pass "graphql-endpoint must start with /" || fail "endpoint message"; fi
if run_args DOCS_TOKEN=good-token -- --graphql; then fail "flag with no value should fail"; else grep -q "needs a value" "$WORK/stderr" && pass "--graphql with no value" || fail "no value message"; fi
if run_args DOCS_TOKEN=good-token -- --bogus; then fail "unknown flag should fail"; else grep -q "unknown argument" "$WORK/stderr" && pass "unknown flag" || fail "unknown flag message"; fi

# Event manifest (docs-platform-0 16.3): docs/events.json by convention, an explicit path, or none.
mkdir -p docs
echo '{"produces":[{"topic":"demo.thing.created"}],"consumes":[{"topic":"docs.source.published","group":"demo"}]}' > docs/events.json
run DOCS_TOKEN=good-token DOCS_SOURCE_KEY=ev-default DOCS_VERSION=1.0.0 \
  && [ "$(last '.body.events.produces[0].topic')" = demo.thing.created ] && [ "$(last '.body.events.consumes[0].group')" = demo ] \
  && grep -q "with events from docs/events.json" "$WORK/stdout" \
  && pass "docs/events.json is sent as events by default" || fail "default events"

echo '{"produces":[],"consumes":[{"topic":"a.b","group":"g"}]}' > events-alt.json
run DOCS_TOKEN=good-token DOCS_SOURCE_KEY=ev-env DOCS_VERSION=1.0.0 DOCS_EVENTS=events-alt.json \
  && [ "$(last '.body.events.consumes[0].topic')" = a.b ] && pass "events input (env) overrides the default" || fail "events env"
run_args DOCS_TOKEN=good-token DOCS_SOURCE_KEY=ev-flag DOCS_VERSION=1.0.0 -- --events events-alt.json \
  && [ "$(last '.body.events.consumes[0].group')" = g ] && pass "--events flag" || fail "--events flag"
run_args DOCS_TOKEN=good-token DOCS_SOURCE_KEY=ev-flag2 DOCS_VERSION=1.0.0 -- --events=events-alt.json \
  && [ "$(last '.body.events.consumes[0].group')" = g ] && pass "--events=file form" || fail "--events= form"
run DOCS_TOKEN=good-token DOCS_SOURCE_KEY=ev-none DOCS_VERSION=1.0.0 DOCS_EVENTS=none \
  && [ "$(last '.body | has("events")')" = false ] && pass "events none: no manifest sent" || fail "events none"
run DOCS_DRY_RUN=true DOCS_SOURCE_KEY=ev-dry DOCS_VERSION=1.0.0 && grep -q "events from docs/events.json" "$WORK/stdout" \
  && grep -q '"demo.thing.created"' "$WORK/stdout" && pass "dry run shows the events" || fail "events dry run"
if run DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 DOCS_EVENTS=missing.json; then fail "missing events should fail"; else grep -q "event manifest not found" "$WORK/stderr" && pass "missing event manifest" || fail "missing events message"; fi
for bad in '[]' '{"produces":{}}' '{"consumes":"x"}' '{"produces":[],"emits":[]}' 'not json'; do
  echo "$bad" > bad-events.json
  if run DOCS_TOKEN=good-token DOCS_VERSION=1.0.0 DOCS_EVENTS=bad-events.json; then fail "bad events $bad should fail"; else grep -q "produces / consumes arrays" "$WORK/stderr" && pass "bad event manifest refused: $bad" || fail "bad events message: $bad"; fi
done
rm -r docs
run DOCS_TOKEN=good-token DOCS_SOURCE_KEY=ev-absent DOCS_VERSION=1.0.0 && [ "$(last '.body | has("events")')" = false ] \
  && pass "no docs/events.json: no manifest sent" || fail "no events file"

rm package.json
if run DOCS_TOKEN=good-token; then fail "no key should fail"; else grep -q "source-key is required" "$WORK/stderr" && pass "no package.json: key required" || fail "key message"; fi
run DOCS_TOKEN=good-token DOCS_SOURCE_KEY=spec-only DOCS_REF_NAME=main && [ "$(output version)" = 0.9.0 ] \
  && pass "no package.json: version from info.version" || fail "info.version default"
if run_args DOCS_TOKEN=good-token DOCS_SOURCE_KEY=gql-nover DOCS_REF_NAME=main -- --graphql schema.graphql; then fail "graphql with no version should fail"; else grep -q "version is required" "$WORK/stderr" && pass "no package.json, GraphQL: version required" || fail "graphql version message"; fi

echo
[ "$fails" -eq 0 ] && echo "publish-docs: all tests passed" || { echo "publish-docs: $fails failed"; exit 1; }
