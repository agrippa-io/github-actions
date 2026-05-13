# `npm/actions/*` — composite actions for Node/npm projects

Composite actions that encapsulate the repetitive parts of an npm-publishing
GitHub Actions workflow. They're the building blocks; reusable workflows
(`*.yml` under [`../.github/workflows`](../.github/workflows)) will compose
them into full pipelines.

| Action | Purpose |
| ------ | ------- |
| [`setup-yarn-project`](#setup-yarn-project) | `setup-node` + scoped npm registry + `yarn install --frozen-lockfile` |
| [`bump-package-json`](#bump-package-json) | Verified-signed commit that updates `package.json#version` on a branch, via the contents API |
| [`compute-prerelease-version`](#compute-prerelease-version) | Append a suffix to the base version and pin `package.json` in-runner |
| [`playwright-cached-chromium`](#playwright-cached-chromium) | Cache + install Playwright Chromium for browser-based tests |
| [`create-release-and-tag`](#create-release-and-tag) | `repos.createRelease` wrapper that pins the tag to a specific commit |

## Pinning

Reference these actions from a consumer workflow by the repo path:

```yaml
- uses: agrippa-io/github-actions/npm/actions/setup-yarn-project@v1
```

Use git tags (`@v1`, `@v1.2.0`), not `@main` — a floating ref means every
consumer breaks the instant the shared repo gets a bad commit. Tag from
`main` after the consumer's CI has been validated against `@main`.

---

## `setup-yarn-project`

Encapsulates the three lines every npm-publishing job repeats:

```yaml
- uses: actions/setup-node@v4
  with: { node-version-file: '.nvmrc', cache: 'yarn', registry-url: '...', scope: '...' }
- env: { NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }} }
  run: yarn install --frozen-lockfile
```

Caller is responsible for `actions/checkout@v4` because checkout options vary
too much by job (different `ref`, `fetch-depth`, `token`) to bake in here.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `node-version-file` | no | `.nvmrc` | Passed to `actions/setup-node` |
| `npm-scope` | **yes** | — | npm scope (`@agrippa-io` or `agrippa-io`) |
| `registry-url` | no | `https://registry.npmjs.org` | Registry the scope authenticates against |
| `npm-token` | **yes** | — | Pass a secret (e.g. `secrets.NPM_TOKEN`); never hardcode |

```yaml
- uses: actions/checkout@v4
- uses: agrippa-io/github-actions/npm/actions/setup-yarn-project@v1
  with:
    npm-scope: '@agrippa-io'
    npm-token: ${{ secrets.NPM_TOKEN }}
```

---

## `bump-package-json`

Issues a verified-signed commit to a named branch that updates
`package.json#version` via `PUT /repos/:owner/:repo/contents/:path`. Works
under "require signed commits" branch protection because commits made
through the API are auto-signed by `github-actions[bot]` — unlike a local
`git commit && git push` from CI.

Does **not** require an `actions/checkout` to have run.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `branch` | **yes** | — | Branch to commit on |
| `version` | **yes** | — | New version string (caller validates semver) |
| `path` | no | `package.json` | Path to the file within the repo |
| `repository` | no | `${{ github.repository }}` | `owner/name` |
| `commit-message` | no | `chore(release): set version to <version>` | Override the default message |
| `gh-token` | **yes** | — | Token with `Contents: read and write` |

| Output | Description |
| ------ | ----------- |
| `commit-sha` | SHA of the created commit |

```yaml
- uses: agrippa-io/github-actions/npm/actions/bump-package-json@v1
  with:
    branch: release/${{ inputs.version }}
    version: ${{ inputs.version }}
    gh-token: ${{ secrets.RELEASE_TOKEN }}
```

> The default `GITHUB_TOKEN` *can* work if the calling job declares
> `permissions: contents: write` and the target branch isn't protected
> against `GITHUB_TOKEN` commits. For pushes that need to trigger downstream
> workflows (push to a release branch triggering staging publish), use a PAT
> instead — `GITHUB_TOKEN` pushes don't fire workflow events.

---

## `compute-prerelease-version`

Reads the base version from `package.json`, appends a caller-supplied
suffix, and runs `npm version <base>-<suffix> --no-git-tag-version
--allow-same-version`. The change lives in the runner only; pair with a
subsequent `npm publish` step.

Run **after** `actions/checkout` — this action reads/writes the local file.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `suffix` | **yes** | — | Suffix appended after a `-` (e.g. `canary.abc1234`, `dev.42.abc1234`, `rc.17`) |
| `path` | no | `package.json` | Path to the package.json |

| Output | Description |
| ------ | ----------- |
| `base-version` | The base version before the suffix was applied |
| `version` | The full prerelease version pinned into package.json |

```yaml
- uses: agrippa-io/github-actions/npm/actions/compute-prerelease-version@v1
  id: version
  with:
    suffix: canary.${{ env.SHORT_SHA }}
- run: npm publish --tag canary --access restricted
- run: echo "Published ${{ steps.version.outputs.version }}"
```

---

## `playwright-cached-chromium`

Caches `~/.cache/ms-playwright` keyed on `hashFiles(<files>)`. On a hit,
runs `install-deps chromium` (re-fetches the apt-level system libraries,
which aren't cached) — on a miss, runs `install chromium --with-deps`
(downloads the ~90 MB browser plus system deps).

Run **after** the install step that resolved `node_modules` — `npx
playwright` needs the resolved tree.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `cache-key-files` | no | `yarn.lock` | Files passed to `hashFiles()` to derive the cache key |
| `cache-path` | no | `~/.cache/ms-playwright` | Where Playwright stores browsers |

| Output | Description |
| ------ | ----------- |
| `cache-hit` | `true` on restore, `false` on miss |

```yaml
- uses: agrippa-io/github-actions/npm/actions/setup-yarn-project@v1
  with: { npm-scope: '@agrippa-io', npm-token: ${{ secrets.NPM_TOKEN }} }
- uses: agrippa-io/github-actions/npm/actions/playwright-cached-chromium@v1
```

---

## `create-release-and-tag`

Wraps `octokit.rest.repos.createRelease`. The tag is created remotely at
`target-commitish` (defaults to the workflow's triggering SHA), so the job
doesn't need to `git push` to a protected branch.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `tag` | **yes** | — | Tag name (e.g. `v0.1.0`) |
| `name` | no | `<tag>` | Human-readable release title |
| `target-commitish` | no | `${{ github.sha }}` | Commit the tag should point at |
| `body` | no | `''` | Release body (ignored when `generate-release-notes: true`) |
| `generate-release-notes` | no | `'true'` | Auto-generate notes from PRs since the previous tag |
| `prerelease` | no | `'false'` | Mark as a prerelease |
| `draft` | no | `'false'` | Create as a draft |

| Output | Description |
| ------ | ----------- |
| `release-id` | Numeric ID of the created release |
| `release-url` | HTML URL of the created release |

```yaml
permissions:
  contents: write
steps:
  - uses: agrippa-io/github-actions/npm/actions/create-release-and-tag@v1
    with:
      tag: v${{ steps.version.outputs.version }}
```

The calling job **must** declare `permissions: contents: write` — the GitHub
token used implicitly by `actions/github-script` needs it for both the
release and tag creation.
