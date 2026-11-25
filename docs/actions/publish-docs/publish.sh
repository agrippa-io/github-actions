#!/usr/bin/env bash
# publish-docs: PUT a spec to node-service-docs (docs-platform-0 2.7).
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
#   DOCS_FORMAT       openapi
#   DOCS_GIT_SHA      commit (default GITHUB_SHA)
#   DOCS_REF_NAME     branch (default GITHUB_REF_NAME)
#   DOCS_DRY_RUN      true → print the request, send nothing
# Writes `outcome`, `version`, `status` to $GITHUB_OUTPUT when set.
set -euo pipefail

die() { echo "::error::publish-docs: $*" >&2; exit 1; }
out() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }

: "${DOCS_API_URL:?api-url is required}"
SPEC="${DOCS_SPEC_PATH:-openapi.json}"
FORMAT="${DOCS_FORMAT:-openapi}"
KIND="${DOCS_KIND:-service}"
SHA="${DOCS_GIT_SHA:-${GITHUB_SHA:-}}"
REF="${DOCS_REF_NAME:-${GITHUB_REF_NAME:-}}"

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

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
jq -n \
  --arg kind "$KIND" --arg name "$NAME" --arg format "$FORMAT" \
  --arg spaceKey "${DOCS_SPACE_KEY:-}" --arg spaceId "${DOCS_SPACE_ID:-}" \
  --arg sha "$SHA" --slurpfile doc "$SPEC" '
  { kind: $kind, name: $name, format: $format, document: $doc[0] }
  + (if $spaceKey != "" then { docSpaceKey: $spaceKey } else {} end)
  + (if $spaceId != "" then { docSpaceId: $spaceId } else {} end)
  + (if ($sha | test("^[0-9a-f]{7,40}$")) then { gitSha: $sha } else {} end)' > "$BODY"

URL="${DOCS_API_URL%/}/sources/$KEY/versions/$VERSION"
out version "$VERSION"

if [ "${DOCS_DRY_RUN:-false}" = "true" ]; then
  echo "publish-docs (dry run): PUT $URL"
  jq '.document = "<\(.document | tostring | length) bytes>"' "$BODY"
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

RESP="$(mktemp)"
trap 'rm -f "$BODY" "$RESP"' EXIT
STATUS="$(curl -sS -o "$RESP" -w '%{http_code}' -X PUT "$URL" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary "@$BODY")" || die "request to $URL failed"
out status "$STATUS"

case "$STATUS" in
  201) echo "publish-docs: published $KEY@$VERSION"; out outcome created ;;
  200) echo "publish-docs: $KEY@$VERSION already published with the same content (no-op)"; out outcome unchanged ;;
  409) cat "$RESP" >&2; die "$KEY@$VERSION is already published with different content (versions are immutable; bump the version)" ;;
  *) cat "$RESP" >&2; die "PUT $URL answered $STATUS" ;;
esac
