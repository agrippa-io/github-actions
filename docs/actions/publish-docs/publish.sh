#!/usr/bin/env bash
# publish-docs: PUT a spec to node-service-docs (docs-platform-0 2.7; GraphQL 5.5).
#
# Reads its inputs from the environment (the composite action maps them):
#   DOCS_API_URL      base URL of the docs API, e.g. https://api.example.com/docs/v1
#   DOCS_TOKEN        a client-credentials token with the docs:publish scope, or
#   DOCS_TOKEN_URL + DOCS_CLIENT_ID + DOCS_CLIENT_SECRET to fetch one
#   DOCS_SOURCE_KEY   source slug (default: package.json name without scope)
#   DOCS_VERSION      version label (default: computed, see below)
#   DOCS_KIND         service | library | application
#   DOCS_NAME         display name (default: the spec's info.title)
#   DOCS_SPACE_KEY / DOCS_SPACE_ID   doc space for the first publish
#   DOCS_SPEC_PATH    the spec file (default openapi.json)
#   DOCS_FORMAT       openapi | graphql (graphql is implied by the two below)
#   DOCS_GRAPHQL      a GraphQL SDL file (docs-platform-0 5.5)
#   DOCS_GRAPHQL_URL  a GraphQL endpoint to introspect, local env only (D1)
#   DOCS_GRAPHQL_ENDPOINT  path the operations are POSTed to (default: the
#                     introspected URL's path, else the docs service's /graphql)
#   DOCS_EVENTS       the event manifest (docs-platform-0 16.3): topics the
#                     service produces / consumes. Default: docs/events.json
#                     when it exists; `none` sends no manifest
#   DOCS_GIT_SHA      commit (default GITHUB_SHA)
#   DOCS_REF_NAME     branch (default GITHUB_REF_NAME)
#   DOCS_DRY_RUN      true → print the request, send nothing
# The same GraphQL settings and dry run also come as flags, for local use:
#   publish.sh --graphql schema.graphql | --graphql-url http://localhost:4370/v1/graphql
#              [--graphql-endpoint /graphql] [--events docs/events.json] [--dry-run]
# Writes `outcome`, `version`, `status` to $GITHUB_OUTPUT when set.
set -euo pipefail

die() { echo "::error::publish-docs: $*" >&2; exit 1; }
out() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --graphql|--graphql-url|--graphql-endpoint|--events)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --graphql) DOCS_GRAPHQL="$2" ;;
        --graphql-url) DOCS_GRAPHQL_URL="$2" ;;
        --graphql-endpoint) DOCS_GRAPHQL_ENDPOINT="$2" ;;
        --events) DOCS_EVENTS="$2" ;;
      esac
      shift 2 ;;
    --events=*) DOCS_EVENTS="${1#*=}"; shift ;;
    --graphql=*) DOCS_GRAPHQL="${1#*=}"; shift ;;
    --graphql-url=*) DOCS_GRAPHQL_URL="${1#*=}"; shift ;;
    --graphql-endpoint=*) DOCS_GRAPHQL_ENDPOINT="${1#*=}"; shift ;;
    --dry-run) DOCS_DRY_RUN=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

: "${DOCS_API_URL:?api-url is required}"
SPEC="${DOCS_SPEC_PATH:-openapi.json}"
FORMAT="${DOCS_FORMAT:-openapi}"
KIND="${DOCS_KIND:-service}"
SHA="${DOCS_GIT_SHA:-${GITHUB_SHA:-}}"
REF="${DOCS_REF_NAME:-${GITHUB_REF_NAME:-}}"
GQL_FILE="${DOCS_GRAPHQL:-}"
GQL_URL="${DOCS_GRAPHQL_URL:-}"
GQL_ENDPOINT="${DOCS_GRAPHQL_ENDPOINT:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# True when a URL's host is this machine (loopback, *.localhost) or the
# docker host: pulling a live schema is for the local environment only (D1).
is_local_url() {
  local host="${1#*://}"
  host="${host%%[/?#]*}"
  # No userinfo or backslashes: they make the host ambiguous between this
  # check and curl.
  case "$host" in *@*|*\\*) return 1 ;; esac
  case "$host" in
    \[*\]*) host="${host%%]*}"; host="${host#[}" ;;
    *) host="${host%%:*}" ;;
  esac
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$host" in
    localhost|*.localhost|127.*|::1|0:0:0:0:0:0:0:1|host.docker.internal) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "$GQL_FILE" ] && [ -n "$GQL_URL" ]; then
  die "pass graphql (an SDL file) or graphql-url, not both"
fi
if [ -n "$GQL_FILE$GQL_URL" ]; then
  [ "$FORMAT" = openapi ] || [ "$FORMAT" = graphql ] || die "format $FORMAT does not take a GraphQL schema"
  FORMAT=graphql
fi
if [ "$FORMAT" = graphql ] && [ -z "$GQL_FILE$GQL_URL" ]; then
  die "format graphql needs graphql (an SDL file) or graphql-url"
fi

case "$GQL_ENDPOINT" in
  ''|/*) ;;
  *) die "graphql-endpoint must be a path starting with /: $GQL_ENDPOINT" ;;
esac

if [ -n "$GQL_FILE" ]; then
  [ -f "$GQL_FILE" ] || die "GraphQL schema not found: $GQL_FILE"
  grep -q '[^[:space:]]' "$GQL_FILE" || die "GraphQL schema is empty: $GQL_FILE"
  SPEC="$TMP/graphql.json"
  jq -n --rawfile sdl "$GQL_FILE" --arg endpoint "$GQL_ENDPOINT" \
    '{ sdl: $sdl } + (if $endpoint != "" then { endpoint: $endpoint } else {} end)' > "$SPEC"
elif [ -n "$GQL_URL" ]; then
  case "$GQL_URL" in http://*|https://*) ;; *) die "graphql-url must be an http(s) URL: $GQL_URL" ;; esac
  is_local_url "$GQL_URL" \
    || die "graphql-url must point at the local environment (localhost, 127.0.0.1, ::1, *.localhost); publish the SDL file from CI instead: $GQL_URL"
  if [ -z "$GQL_ENDPOINT" ]; then
    GQL_PATH="${GQL_URL#*://}"
    case "$GQL_PATH" in */*) GQL_PATH="/${GQL_PATH#*/}" ;; *) GQL_PATH="" ;; esac
    GQL_PATH="${GQL_PATH%%[?#]*}"
    [ "$GQL_PATH" = / ] && GQL_PATH=""
    GQL_ENDPOINT="$GQL_PATH"
  fi
  jq -n --rawfile query "$HERE/introspection.graphql" \
    '{ operationName: "IntrospectionQuery", query: $query }' > "$TMP/introspect.json"
  GQL_STATUS="$(curl -sS -o "$TMP/introspection.json" -w '%{http_code}' -X POST "$GQL_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/graphql-response+json, application/json' \
    --data-binary "@$TMP/introspect.json")" || die "introspection request to $GQL_URL failed"
  case "$GQL_STATUS" in 2*) ;; *) head -c 2000 "$TMP/introspection.json" >&2; die "introspection of $GQL_URL answered $GQL_STATUS" ;; esac
  jq -e '.data.__schema | type == "object"' "$TMP/introspection.json" > /dev/null 2>&1 || {
    jq -r '.errors[]?.message // empty' "$TMP/introspection.json" >&2 2>/dev/null || true
    die "introspection of $GQL_URL returned no data.__schema"
  }
  SPEC="$TMP/graphql.json"
  jq --arg endpoint "$GQL_ENDPOINT" \
    '{ __schema: .data.__schema } + (if $endpoint != "" then { endpoint: $endpoint } else {} end)' \
    "$TMP/introspection.json" > "$SPEC"
  echo "publish-docs: introspected $GQL_URL"
fi

# Event manifest (docs-platform-0 16.3): explicit path, `none`, or the
# docs/events.json convention. The docs service validates it fully; this only
# catches a file that is not a manifest-shaped JSON object before the PUT.
EVENTS="${DOCS_EVENTS:-}"
if [ -z "$EVENTS" ] && [ -f docs/events.json ]; then EVENTS=docs/events.json; fi
[ "$EVENTS" = none ] && EVENTS=""
if [ -n "$EVENTS" ]; then
  [ -f "$EVENTS" ] || die "event manifest not found: $EVENTS"
  jq -e 'type == "object" and ((keys - ["produces", "consumes"]) | length == 0)
    and ((.produces // []) | type == "array") and ((.consumes // []) | type == "array")' "$EVENTS" > /dev/null 2>&1 \
    || die "event manifest must be a JSON object with produces / consumes arrays: $EVENTS"
fi

[ -f "$SPEC" ] || die "spec not found: $SPEC"
jq -e 'type == "object"' "$SPEC" > /dev/null 2>&1 || die "spec is not a JSON object: $SPEC"

pkg_field() { [ -f package.json ] && jq -r "$1 // empty" package.json || true; }

KEY="${DOCS_SOURCE_KEY:-$(pkg_field .name | sed 's#^@[^/]*/##')}"
[ -n "$KEY" ] || die "source-key is required (no package.json name to default to)"

# Version: explicit, else package.json version on main / release branches,
# else <version>-dev.<short sha> so develop builds never collide with releases.
VERSION="${DOCS_VERSION:-}"
if [ -z "$VERSION" ]; then
  BASE="$(pkg_field .version)"
  [ -n "$BASE" ] || BASE="$(jq -r '.info.version // empty' "$SPEC")"
  [ -n "$BASE" ] || die "version is required (no package.json or info.version to default to)"
  case "$REF" in
    main|master|release/*) VERSION="$BASE" ;;
    *) VERSION="$BASE-dev.${SHA:0:7}" ;;
  esac
  VERSION="${VERSION%-dev.}"
fi

NAME="${DOCS_NAME:-$(jq -r '.info.title // empty' "$SPEC")}"
[ -n "$NAME" ] || NAME="$KEY"

BODY="$TMP/body.json"
jq -n \
  --arg kind "$KIND" --arg name "$NAME" --arg format "$FORMAT" \
  --arg spaceKey "${DOCS_SPACE_KEY:-}" --arg spaceId "${DOCS_SPACE_ID:-}" \
  --arg sha "$SHA" --slurpfile doc "$SPEC" \
  --slurpfile events "${EVENTS:-/dev/null}" '
  { kind: $kind, name: $name, format: $format, document: $doc[0] }
  + (if $spaceKey != "" then { docSpaceKey: $spaceKey } else {} end)
  + (if $spaceId != "" then { docSpaceId: $spaceId } else {} end)
  + (if ($sha | test("^[0-9a-f]{7,40}$")) then { gitSha: $sha } else {} end)
  + (if ($events | length) > 0 then { events: $events[0] } else {} end)' > "$BODY"

URL="${DOCS_API_URL%/}/sources/$KEY/versions/$VERSION"
out version "$VERSION"

if [ "${DOCS_DRY_RUN:-false}" = "true" ]; then
  echo "publish-docs (dry run): PUT $URL"
  jq '.document = "<\(.document | tostring | length) bytes>"' "$BODY"
  if [ -n "$EVENTS" ]; then echo "publish-docs (dry run): events from $EVENTS"; fi
  out outcome dry-run
  exit 0
fi

TOKEN="${DOCS_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  [ -n "${DOCS_TOKEN_URL:-}" ] && [ -n "${DOCS_CLIENT_ID:-}" ] && [ -n "${DOCS_CLIENT_SECRET:-}" ] \
    || die "token, or token-url + client-id + client-secret, is required"
  TOKEN="$(curl -sS --fail-with-body -X POST "$DOCS_TOKEN_URL" \
    -u "$DOCS_CLIENT_ID:$DOCS_CLIENT_SECRET" \
    -d grant_type=client_credentials -d scope=docs:publish | jq -r '.access_token // empty')" \
    || die "could not fetch a token from token-url"
  [ -n "$TOKEN" ] || die "token-url returned no access_token"
fi
echo "::add-mask::$TOKEN"

RESP="$TMP/response.json"
STATUS="$(curl -sS -o "$RESP" -w '%{http_code}' -X PUT "$URL" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary "@$BODY")" || die "request to $URL failed"
out status "$STATUS"

case "$STATUS" in
  201) echo "publish-docs: published $KEY@$VERSION${EVENTS:+ with events from $EVENTS}"; out outcome created ;;
  200) echo "publish-docs: $KEY@$VERSION already published with the same content (no-op)"; out outcome unchanged ;;
  409) cat "$RESP" >&2; die "$KEY@$VERSION is already published with different content or events (versions are immutable; bump the version)" ;;
  *) cat "$RESP" >&2; die "PUT $URL answered $STATUS" ;;
esac
