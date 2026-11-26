# docs/

Actions for the Agrippa documentation platform (node-service-docs,
docs-platform-0).

## `publish-docs`

`agrippa-io/github-actions/docs/actions/publish-docs@v1`: publishes a repo's
spec (OpenAPI, or a GraphQL schema) to the docs API with
`PUT /sources/:key/versions/:version` (node-service-docs
`src/routes/sources/README.md`). Services **push** their docs from CI on merge;
the docs service never scrapes anything.

**When to run:** on push to `develop` and `main` (and `release/**`), after the
spec is built or checked in.

**Auth:** a client-credentials token with the `docs:publish` scope: pass
`token`, or `token-url` + `client-id` + `client-secret` and the action fetches
one (`grant_type=client_credentials`, `scope=docs:publish`). The token is
masked in logs.

**Version:** `version`, else the `package.json` version on `main`, `master`
and `release/*`, else `<version>-dev.<short sha>` (develop builds never collide
with releases). Without a `package.json`, the spec's `info.version`.
Versions are immutable on the docs side: re-publishing the same content is a
no-op (200, success), different content under the same version fails (409).

| Input | Default | Meaning |
| --- | --- | --- |
| `api-url` | (required) | docs API base, e.g. `https://api.example.com/docs/v1` |
| `token` | | `docs:publish` access token |
| `token-url`, `client-id`, `client-secret` | | fetch the token instead |
| `source-key` | package name without scope | source slug |
| `version` | see above | version label |
| `kind` | `service` | `service` · `library` · `application` |
| `name` | spec `info.title` | display name |
| `doc-space-key` / `doc-space-id` | | doc space, needed on a source's first publish |
| `spec-path` | `openapi.json` | spec file |
| `format` | `openapi` | `openapi` or `graphql` (implied by the next two) |
| `graphql` | | GraphQL SDL file, e.g. `schema.graphql`: publishes it instead of `spec-path` |
| `graphql-url` | | GraphQL endpoint to introspect instead, **local environment only** |
| `graphql-endpoint` | `graphql-url` path, else `/graphql` | path the operations are POSTed to |
| `events` | `docs/events.json` when it exists | the service's event manifest (topics it produces / consumes); `none` sends none |
| `working-directory` | `.` | where `package.json` and the spec live |
| `dry-run` | `false` | print the request, send nothing |

| Output | Meaning |
| --- | --- |
| `outcome` | `created` · `unchanged` · `dry-run` |
| `version` | the version label used |
| `status` | HTTP status of the publish call |

```yaml
on:
  push:
    branches: [develop, main]

jobs:
  publish-docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: agrippa-io/github-actions/docs/actions/publish-docs@v1
        with:
          api-url: ${{ vars.DOCS_API_URL }}
          token-url: ${{ vars.OIDC_TOKEN_URL }}
          client-id: ${{ vars.DOCS_PUBLISH_CLIENT_ID }}
          client-secret: ${{ secrets.DOCS_PUBLISH_CLIENT_SECRET }}
          doc-space-key: platform
```

### Event manifest

A Kafka-using service commits `docs/events.json`, the topics it **produces**
(through its outbox) and **consumes** (its `@agrippa-io/node-events` runners,
each in a consumer group), and the action sends it as `events` with the spec
(docs-platform-0 16.3; node-service-docs `src/lib/eventManifest`). The docs
service builds the event-flow graph from every service's manifest
(`GET /docs/v1/events/flow`). The manifest is as immutable as the version: a
changed manifest needs a new version, like a changed spec.

```json
{
  "produces": [{ "topic": "catalog.product.created", "via": "outbox" }],
  "consumes": [{ "topic": "docs.source.published", "group": "catalog-docs" }]
}
```

Pass `events: path/to/manifest.json` for another location, or `events: none`
to send none. The action only checks the file is an object with `produces` /
`consumes` arrays; the docs service validates the rest (400).

### GraphQL

Pass `graphql: schema.graphql` (an SDL file) and the action publishes
`format: graphql` with `document: { sdl, endpoint? }`; the docs service turns
each root field into an operation (`query.<field>`, `mutation.<field>`,
`subscription.<field>`; node-service-docs `src/lib/graphql`). `name` defaults
to the source key (SDL has no title), and the version comes from
`package.json` (there is no `info.version` to fall back to).

```yaml
      - uses: agrippa-io/github-actions/docs/actions/publish-docs@v1
        with:
          api-url: ${{ vars.DOCS_API_URL }}
          token: ${{ secrets.DOCS_PUBLISH_TOKEN }}
          graphql: schema.graphql
          graphql-endpoint: /docs/v1/graphql
```

`graphql-url` introspects a running server instead (the standard
graphql-js introspection query in `publish-docs/introspection.graphql`) and
publishes `{ __schema, endpoint }`, the endpoint defaulting to the URL's path.
Pulling a live schema is for the **local environment only** (D1: the docs
service never scrapes a deployed one), so the URL must be `localhost`,
`*.localhost`, `127.x`, `::1` or `host.docker.internal` (no userinfo); anything
else fails the step. In CI, check in or build the SDL and use `graphql`, or
start the service in the job and introspect it on `localhost`.

The script takes the same settings as flags, for a publish from a laptop
against the local stack:

```bash
DOCS_API_URL=http://localhost:4370/v1 DOCS_TOKEN=… \
  docs/actions/publish-docs/publish.sh --graphql schema.graphql [--graphql-endpoint /graphql] [--dry-run]
DOCS_API_URL=… DOCS_TOKEN=… publish.sh --graphql-url http://localhost:4370/v1/graphql
```

Recipes and error catalogs ride along once the docs API accepts them (later
docs-platform-0 slices); today only the spec is sent.

**Tests:** `bash docs/actions/publish-docs/test/run.sh` runs the script against
a local stub API (python3, jq, curl), which also plays a GraphQL server
answering introspection from `test/fixtures/` (an SDL and its introspection
result); CI (`test-publish-docs.yml`) adds shellcheck and dry runs of the
composite action (OpenAPI and GraphQL SDL).

## `sdk-contract-stack`

`agrippa-io/github-actions/docs/actions/sdk-contract-stack@v1`: starts the local
stack the SDK repos' **contract suites** run against (docs-platform-0 15.6):
`node-auth-service`, `node-service-authz` and `node-service-docs`, checked out
and run from source next to throwaway Postgres, Redis, Mongo and OpenFGA
containers. It then publishes the auth and authz specs and docs' own GraphQL
schema (`docs/schema.graphql`, D3) to docs (as their CI does on merge, D1) and
waits for ingestion, and seeds a fixture: a platform
admin (`system.admin`) who owns one organization. Everything is `localhost`;
no cloud host is ever touched.

**Used by:** the `contract` job of `sdk-typescript`, `sdk-python` and `sdk-java`.

**Auth:** `token` must read the three private service repos
(`secrets.RELEASE_TOKEN`); `GITHUB_TOKEN` only reads the calling repo. Service
tokens come from `node-auth-service`'s `/dev/token` (never mounted in
production), so authz and docs verify real RS256 tokens against its JWKS.

| Input | Default | Meaning |
| --- | --- | --- |
| `token` | (required) | reads `agrippa-io/node-auth-service`, `node-service-authz`, `node-service-docs` |
| `npm-token` | (required) | the services' private `@agrippa-io` dependencies |
| `auth-ref` / `authz-ref` / `docs-ref` | `main` / `main` / `develop` | the refs to run |
| `path` | `.contract-stack` | checkouts, logs and the env file |

| Output | Meaning |
| --- | --- |
| `env-file` | the env file; everything but the password is also appended to `GITHUB_ENV` |
| `script` | `stack.sh`, for `logs` / `down` later in the job |

Exported to the job; `AGRIPPA_CONTRACT_PASSWORD` is only in the env file (GitHub
prints every step's env), so source the file in the step that runs the suite:

| Variable | Value |
| --- | --- |
| `AGRIPPA_CONTRACT_AUTH_URL` / `_AUTHZ_URL` / `_DOCS_URL` | `http://localhost:4200` / `:4201` / `:4370` |
| `AGRIPPA_CONTRACT_AUTH_VERSION` / `_AUTHZ_VERSION` / `_DOCS_VERSION` | the published versions (`info.version`; docs: its `package.json` version) |
| `AGRIPPA_CONTRACT_EMAIL` / `_PASSWORD` | the fixture platform admin (a generated test value; the password is env-file only) |
| `AGRIPPA_CONTRACT_ORG_KEY` | the `org-key` of the organization it owns |

```yaml
contract:
  runs-on: ${{ vars.RUNNER || 'ubuntu-latest' }}
  steps:
    - uses: actions/checkout@v4
    - id: stack
      uses: agrippa-io/github-actions/docs/actions/sdk-contract-stack@v1
      with:
        token: ${{ secrets.RELEASE_TOKEN }}
        npm-token: ${{ secrets.NPM_TOKEN }}
    - env:
        ENV_FILE: ${{ steps.stack.outputs.env-file }}
      run: |
        set -a; . "$ENV_FILE"; set +a
        npm run test:contract
    - if: failure()
      run: ${{ steps.stack.outputs.script }} logs
```

**Locally** the same script runs against your own checkouts (Docker needed;
ports 4200 / 4201 / 4370 free, container ports 55432 / 56379 / 57017 / 58080):

```bash
STACK_AUTH_DIR=../../services/node-auth-service \
STACK_AUTHZ_DIR=../../services/node-service-authz \
STACK_DOCS_DIR=../../services/node-service-docs \
  ../../github-actions/docs/actions/sdk-contract-stack/stack.sh up
set -a; . .contract-stack/env; set +a      # then run the SDK's contract suite
../../github-actions/docs/actions/sdk-contract-stack/stack.sh down
```

`STACK_*_PORT`, `STACK_NAME` (container prefix, default `sdk-contract`),
`STACK_STATE_DIR` and `STACK_WAIT_SECONDS` override the defaults. `up` refuses
a service port that is already taken. `logs` prints the last lines of each
service log.
`stack.sh publish <source key> <openapi.json>` publishes one more spec (its
`info.version`) to the running stack's docs service and waits for ingest; the
`sdk-release-plan` tests publish their fixture versions with it.

What the seed does that no API does (on purpose, in a throwaway database only):
runs auth's `seedSystemPoliciesAndRoles`, binds a `system.admin` policy to the
`system.admin` role (the organization admin routes check it, and the seed
doesn't create it), makes the fixture user a system admin, and adds them to
their organization as `organization.owner`. It also inserts the public
`platform` doc space the specs are published into.

## `sdk-release-plan`

`agrippa-io/github-actions/docs/actions/sdk-release-plan@v1.12.0`: plans (and
with `write: 'true'`, applies) the next release of a generated SDK repo
(docs-platform-0 15.7, decision D10). One planner serves `sdk-typescript`,
`sdk-python` and `sdk-java`, so a docs change gets **the same version bump in
every language**.

For each SDK in the manifest (`sdks.json`), in order:

1. `GET <docs-url>/sources/<key>/versions/<version>/sdk-model`: the client model now.
2. Compare it with the pinned `models/<key>.json`, byte for byte.
3. Pick the bump:

| Case | Bump |
| --- | --- |
| the model is unchanged | none: no release |
| no pinned model yet (a new SDK) | first release, at the manifest version |
| same docs version, different model (the generator changed) | patch |
| the 2.6 diff (`GET /sources/<key>/diff?from=<pinned>&to=<new>`) says `breaking` | **major** |
| the diff has any other change | minor |
| the diff is empty | patch |
| no diff (the old version isn't in this docs service, or it's down) | **major**: a major never breaks a client, a missed one does |

A breaking change is a major even below 1.0 (`0.4.1` → `1.0.0`).

4. With `write`: store the new model, set the manifest version, and add a
   `## <date>` section to `CHANGELOG.md` (after `## Unreleased` when there is
   one) with one `### <package> <version> (<bump>)` entry per released SDK,
   listing the diff's changes (breaking ones first, up to 50).

Regenerating the packages from the new models is the caller's job (each SDK
repo's own `generate`), as are the release PR and the publish.

**Manifest** (`sdks.json`, at the repo root):

```json
{
  "node-auth-service": { "version": "0.1.0", "package": "@agrippa-io/sdk-node-auth-service" },
  "node-service-authz": { "version": "0.1.0", "package": "@agrippa-io/sdk-node-service-authz" }
}
```

`package` only names the SDK in the changelog and the summary (default: the key).

| Input | Default | Meaning |
| --- | --- | --- |
| `docs-url` | (required) | docs API base (`http://localhost:4370`, or `<gateway>/docs/v1`) |
| `token` | | optional docs read token (tenant / internal doc spaces) |
| `version` | `latest` | the docs version to release from |
| `manifest` / `models` / `changelog` | `sdks.json` / `models` / `CHANGELOG.md` | the repo's files |
| `write` | `false` | `true` writes the models, manifest and changelog |
| `working-directory` | `.` | the paths above are relative to it |

| Output | Meaning |
| --- | --- |
| `changed` | `true` when some SDK has a release |
| `bump` | the largest bump: `none` · `patch` · `minor` · `major` |
| `plan` | path of the plan JSON (per SDK: `from`, `to`, `bump`, `reason`, `changes`) |

The step summary has a table of every SDK with its bump and why. A model the
docs service can't serve fails the step (nothing is written).

```yaml
- id: plan
  uses: agrippa-io/github-actions/docs/actions/sdk-release-plan@v1.12.0
  with:
    docs-url: ${{ vars.DOCS_URL }}
    write: 'true'
- if: steps.plan.outputs.changed == 'true'
  run: npm run generate   # then test and open the release PR
```

**Locally:** `node docs/actions/sdk-release-plan/plan.mjs --docs-url http://localhost:4370`
from an SDK repo prints the plan; add `--write` to apply it.

**Tests** (`test-sdk-release-plan.yml`): `test/plan.test.mjs` (unit, a fake docs
service, 100% coverage) and `test/live.sh`, which publishes three versions of a
fixture spec to a real docs service (the `sdk-contract-stack`) and checks an
added operation gives a minor and a removed one a major, in a TypeScript-,
Python- and Java-shaped repo.
