#!/usr/bin/env bash
# cost-inventory: ask the Cost Planner to sync its inventory after a push
# (cost-planner-0 2.4, D2). Reads its inputs from the environment:
#   COST_PLANNER_URL    planner base URL, e.g. https://api.example.com/cost-planner/v1
#   COST_PLANNER_TOKEN  the planner's INVENTORY_SYNC_TRIGGER_TOKEN
#   COST_REPO / COST_REF / COST_SHA   what changed (default GITHUB_REPOSITORY /
#                       GITHUB_REF_NAME / GITHUB_SHA); informational for the planner
#   COST_EVENT          event name (default GITHUB_EVENT_NAME, else push)
#   COST_STRICT         true → a refused or failed call fails the step
#   COST_DRY_RUN        true → print the request, send nothing
#   COST_TIMEOUT        seconds for the call (default 15)
# Writes `outcome` (accepted | skipped | dry-run | failed), `joined`, `status`
# to $GITHUB_OUTPUT when set. Shared by every repo's CI, so it is conservative:
# unconfigured → notice and exit 0; failure → warning and exit 0 unless strict.
set -euo pipefail

out() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }
STRICT="${COST_STRICT:-false}"
case "$STRICT" in true|false) ;; *) echo "::error::cost-inventory: strict must be true or false, not $STRICT" >&2; exit 1 ;; esac

# Not configured: skip, loudly enough to notice, quietly enough to stay green.
URL="${COST_PLANNER_URL:-}"
TOKEN="${COST_PLANNER_TOKEN:-}"
if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
  echo "::notice::cost-inventory: skipped (no planner-url / vars.COST_PLANNER_URL or no trigger token configured)"
  out outcome skipped
  exit 0
fi
case "$URL" in http://*|https://*) ;; *) echo "::error::cost-inventory: planner-url must be an http(s) URL" >&2; exit 1 ;; esac
echo "::add-mask::$TOKEN"

# Refused or unreachable: a warning by default, an error when strict.
fail() {
  out outcome failed
  if [ "$STRICT" = true ]; then echo "::error::cost-inventory: $*" >&2; exit 1; fi
  echo "::warning::cost-inventory: $* (not failing the build; set strict: true to)"
  exit 0
}

REPO="${COST_REPO:-${GITHUB_REPOSITORY:-}}"
REF="${COST_REF:-${GITHUB_REF_NAME:-}}"
SHA="${COST_SHA:-${GITHUB_SHA:-}}"
EVENT="${COST_EVENT:-${GITHUB_EVENT_NAME:-push}}"
BODY="$(jq -cn --arg repo "$REPO" --arg ref "$REF" --arg sha "$SHA" --arg event "$EVENT" '
  {}
  + (if $repo != "" then { repo: $repo } else {} end)
  + (if $ref != "" then { ref: $ref } else {} end)
  + (if ($sha | test("^[0-9a-f]{7,40}$")) then { sha: $sha } else {} end)
  + (if $event != "" then { event: $event } else {} end)')"
TARGET="${URL%/}/webhooks/inventory-sync"

if [ "${COST_DRY_RUN:-false}" = true ]; then
  echo "cost-inventory (dry run): POST $TARGET"
  echo "$BODY"
  out outcome dry-run
  exit 0
fi

RESP="$(mktemp)"
trap 'rm -f "$RESP"' EXIT
STATUS="$(curl -sS -o "$RESP" -w '%{http_code}' --max-time "${COST_TIMEOUT:-15}" -X POST "$TARGET" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data-binary "$BODY" 2>/dev/null)" \
  || fail "could not reach $TARGET"
out status "$STATUS"

case "$STATUS" in
  202)
    JOINED="$(jq -r '.joined // false' "$RESP" 2>/dev/null || echo false)"
    out joined "$JOINED"
    out outcome accepted
    if [ "$JOINED" = true ]; then echo "cost-inventory: the planner was already syncing; this push joined that sync"; else echo "cost-inventory: inventory sync queued for ${REPO:-this repo}"; fi ;;
  401) fail "the planner refused the trigger token (401): check the cost-planner-token secret" ;;
  503) fail "the planner's trigger is not configured (503: INVENTORY_SYNC_TRIGGER_TOKEN unset on the service)" ;;
  *) fail "POST $TARGET answered $STATUS" ;;
esac
