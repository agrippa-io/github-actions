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
