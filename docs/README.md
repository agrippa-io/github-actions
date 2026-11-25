# docs/

Actions for the Agrippa documentation platform (node-service-docs,
docs-platform-0).

## `publish-docs`

`agrippa-io/github-actions/docs/actions/publish-docs@v1`: publishes a repo's
spec (OpenAPI today) to the docs API with
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
| `format` | `openapi` | spec format |
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

Recipes and error catalogs ride along once the docs API accepts them (later
docs-platform-0 slices); today only the spec is sent.

**Tests:** `bash docs/actions/publish-docs/test/run.sh` runs the script against
a local stub API (python3, jq, curl); CI (`test-publish-docs.yml`) adds
shellcheck and a dry run of the composite action.
