#!/usr/bin/env bash
# The planner against a real node-service-docs (the sdk-contract-stack, 15.6):
# publish three versions of a fixture spec, then plan the release of the same
# SDK in a TypeScript-, Python- and Java-shaped repo from the real 2.6 diff.
#   1.0.0 → 1.1.0 adds an operation      → minor in all three
#   1.1.0 → 2.0.0 removes an operation   → major in all three (the slice criterion)
#
# Needs a running stack: STACK_SCRIPT (stack.sh) and ENV_FILE (its env file).
# shellcheck disable=SC2015 # `check && pass || fail`: pass only echoes, never fails
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLAN="$HERE/../plan.mjs"
: "${STACK_SCRIPT:?path of sdk-contract-stack/stack.sh}"
: "${ENV_FILE:?the stack env file}"
# shellcheck source=/dev/null
. "$ENV_FILE"
DOCS="$AGRIPPA_CONTRACT_DOCS_URL"
KEY=sdk-release-fixture
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

for v in 1.0.0 1.1.0 2.0.0; do
  "$STACK_SCRIPT" publish "$KEY" "$HERE/fixtures/fixture-$v.json" > /dev/null || { echo "publishing $KEY@$v failed"; exit 1; }
done

for repo in sdk-typescript:@agrippa-io/sdk-$KEY sdk-python:agrippa-fixture sdk-java:io.agrippa:$KEY-sdk; do
  name="${repo%%:*}"
  dir="$WORK/$name"
  mkdir -p "$dir/models"
  printf '{ "%s": { "version": "0.3.1", "package": "%s" } }\n' "$KEY" "${repo#*:}" > "$dir/sdks.json"
  printf '# Changelog\n\n## Unreleased\n' > "$dir/CHANGELOG.md"
  curl -fsS -o "$dir/models/$KEY.json" "$DOCS/sources/$KEY/versions/1.0.0/sdk-model"
  plan() { (cd "$dir" && node "$PLAN" --docs-url "$DOCS" --version "$1" --plan-out "$dir/plan-$1.json" --date 2026-11-25 --write > "$dir/log-$1" 2>&1); }
  version() { jq -r ".\"$KEY\".version" "$dir/sdks.json"; }

  plan 1.1.0 && [ "$(jq -r .bump "$dir/plan-1.1.0.json")" = minor ] && [ "$(version)" = 0.4.0 ] \
    && grep -q '`operation.added`' "$dir/CHANGELOG.md" \
    && pass "$name: 1.0.0 → 1.1.0 (operation added) is minor: 0.3.1 → 0.4.0" || { fail "$name minor"; cat "$dir/log-1.1.0"; }

  plan 2.0.0 && [ "$(jq -r .bump "$dir/plan-2.0.0.json")" = major ] && [ "$(version)" = 1.0.0 ] \
    && grep -q '\*\*Breaking\*\* `operation.removed`' "$dir/CHANGELOG.md" \
    && pass "$name: 1.1.0 → 2.0.0 (operation removed) is major: 0.4.0 → 1.0.0" || { fail "$name major"; cat "$dir/log-2.0.0"; }

  plan 2.0.0 && [ "$(jq -r .bump "$dir/plan-2.0.0.json")" = none ] && [ "$(version)" = 1.0.0 ] \
    && pass "$name: the same docs version again is no release" || fail "$name none"
done

echo
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
