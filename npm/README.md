# `npm/*` — composite actions and reusable workflows for Node/npm projects

Two layers:

- **Composite actions** under [`npm/actions/`](./actions) — small, single-purpose building blocks (`setup-yarn-project`, `bump-package-json`, etc.). Use these when you want fine-grained control inside an existing job.
- **Reusable workflows** under [`../.github/workflows/`](../.github/workflows/) — opinionated single-job pipelines (`npm-format.yml`, `npm-lint.yml`, etc.) that compose the actions above. Use these when you want a ready-made job; consumers wire them up in their `ci.yml` with `uses:` to fan them out in parallel.

| Composite action | Purpose |
| ---------------- | ------- |
| [`setup-node-project`](#setup-node-project) | Package-manager-agnostic `setup-node` + scoped registry + frozen install (detects yarn vs npm). **Prefer this** for new consumers. |
| [`setup-yarn-project`](#setup-yarn-project) | yarn-only variant of the above; kept for back-compat |
| [`bump-package-json`](#bump-package-json) | Verified-signed commit that updates `package.json#version` on a branch, via the contents API |
| [`compute-prerelease-version`](#compute-prerelease-version) | Append a suffix to the base version and pin `package.json` in-runner |
| [`compute-dev-suffix`](#compute-dev-suffix) | Look up the PR associated with a commit, emit a `dev.<pr>.<sha>` suffix |
| [`playwright-cached-chromium`](#playwright-cached-chromium) | Cache + install Playwright Chromium for browser-based tests |
| [`create-release-and-tag`](#create-release-and-tag) | `repos.createRelease` wrapper that pins the tag to a specific commit |

| Reusable workflow | Purpose |
| ----------------- | ------- |
| [`npm-format.yml`](#npm-formatyml) | `prettier --check` against a configurable source glob |
| [`npm-lint.yml`](#npm-lintyml) | `eslint` with a configurable `--max-warnings` gate |
| [`npm-test.yml`](#npm-testyml) | Run the test suite (default `vitest run --coverage`); optional Playwright Chromium |
| [`npm-build.yml`](#npm-buildyml) | `yarn build` (optional Storybook) + upload `dist/` as an artifact |
| [`npm-publish-prerelease.yml`](#npm-publish-prereleaseyml) | Publish a prerelease build (canary / dev / staging) under a configurable dist-tag |
| [`npm-publish-latest.yml`](#npm-publish-latestyml) | Publish the production release; reads version from `package.json` and creates the `vX.Y.Z` tag remotely |
| [`npm-release-stage.yml`](#npm-release-stageyml) | Cut `release/X.Y.Z`, bump `package.json` via contents API, open draft promotion PR |
| [`gitflow-sync-back.yml`](#gitflow-sync-backyml) | After a release lands on `main`, open a back-merge PR `main → develop` |

> Note: `gitflow-sync-back.yml` is not strictly npm-specific (it's a pure
> gitflow concern) but lives under the same `.github/workflows/` directory
> for convenience.

## Pinning

Reference these actions from a consumer workflow by the repo path:

```yaml
- uses: agrippa-io/github-actions/npm/actions/setup-yarn-project@v1
```

Use git tags (`@v1`, `@v1.2.0`), not `@main` — a floating ref means every
consumer breaks the instant the shared repo gets a bad commit. Tag from
`main` after the consumer's CI has been validated against `@main`.

---

## `setup-node-project`

Package-manager-agnostic project setup. Detects the package manager from the
lockfile (`yarn.lock` → yarn, `package-lock.json` → npm, neither → npm) — or
honors an explicit `package-manager` input — then configures `setup-node`
with the matching cache, points the scope at the registry, and installs from
the frozen lockfile (`yarn install --frozen-lockfile` / `npm ci`). Exposes the
resolved manager as the `package-manager` output so the calling workflow can
choose `yarn` vs `npx` / `npm run` for its own steps.

This supersedes [`setup-yarn-project`](#setup-yarn-project). The four reusable
workflows (`npm-format`/`npm-lint`/`npm-test`/`npm-build`) all use it, which is
why they now work for both yarn (`react-components`) and npm (every node
service) repos.

Caller is responsible for `actions/checkout@v4`.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `node-version-file` | no | `.nvmrc` | Passed to `actions/setup-node` |
| `npm-scope` | **yes** | — | npm scope (`@agrippa-io` or `agrippa-io`) |
| `registry-url` | no | `https://registry.npmjs.org` | Registry the scope authenticates against |
| `npm-token` | **yes** | — | Pass a secret; never hardcode |
| `package-manager` | no | `auto` | `auto` detects from lockfile; force with `yarn` or `npm` |
| `legacy-peer-deps` | no | `false` | `npm ci --legacy-peer-deps` (npm only) |

| Output | Description |
| ------ | ----------- |
| `package-manager` | Resolved manager — `yarn` or `npm` |

```yaml
- uses: actions/checkout@v4
- id: setup
  uses: agrippa-io/github-actions/npm/actions/setup-node-project@v1
  with:
    npm-scope: '@agrippa-io'
    npm-token: ${{ secrets.NPM_TOKEN }}
- run: |
    EXEC=$([ "${{ steps.setup.outputs.package-manager }}" = yarn ] && echo yarn || echo "npx --no-install")
    $EXEC eslint .
```

---

## `setup-yarn-project`

> Legacy — prefer [`setup-node-project`](#setup-node-project) unless you
> specifically want to pin yarn-only behavior.

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

## `compute-dev-suffix`

Look up the PR associated with the triggering commit (via
`repos.listPullRequestsAssociatedWithCommit`) and emit a `dev.<pr>.<sha>`
suffix suitable for feeding into [`npm-publish-prerelease`'s `version-suffix`
input](#npm-publish-prereleaseyml).

Designed for the publish-dev pattern in release workflows: when a PR
merges to `develop`, the resulting dev prerelease should be traceable to
both the PR and the merge commit. This action does that lookup once,
emits the composed suffix, and the publish workflow consumes it.

Falls back to `dev.0.<github.sha>` when the commit isn't associated with
a PR (e.g. a direct push), which is rare but worth handling gracefully.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `sha` | no | `${{ github.sha }}` | Commit SHA to look up |
| `fallback-pr-number` | no | `0` | PR number used when no PR is associated |

| Output | Description |
| ------ | ----------- |
| `suffix` | Composed suffix (`dev.<pr>.<short-sha>`) |
| `pr-number` | PR number (or the fallback) |
| `short-sha` | 7-char SHA used in the suffix |

```yaml
compute-dev-suffix:
  if: github.ref == 'refs/heads/develop'
  needs: build
  runs-on: ubuntu-latest
  permissions: { contents: read, pull-requests: read }
  outputs:
    suffix: ${{ steps.dev.outputs.suffix }}
  steps:
    - id: dev
      uses: agrippa-io/github-actions/npm/actions/compute-dev-suffix@v1

publish-dev:
  needs: [build, compute-dev-suffix]
  uses: agrippa-io/github-actions/.github/workflows/npm-publish-prerelease.yml@v1
  with:
    npm-scope: '@agrippa-io'
    dist-tag: dev
    version-suffix: ${{ needs.compute-dev-suffix.outputs.suffix }}
  secrets:
    npm-token: ${{ secrets.NPM_TOKEN }}
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

---

# Reusable workflows

Each reusable workflow runs as its **own job** in the consumer's `ci.yml`,
which is the whole point of this layer: format / lint / test can fan out
in parallel rather than being sequential steps inside one validate job.

Each one declares its inputs and the `npm-token` secret explicitly. To pass
the secret, the cleanest pattern is per-job:

```yaml
secrets:
  npm-token: ${{ secrets.NPM_TOKEN }}
```

`secrets: inherit` also works if the consumer trusts all the reusable
workflows it calls with all of its secrets.

---

## `npm-format.yml`

`prettier --check` against a configurable source glob.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `npm-scope` | **yes** | — | npm scope |
| `node-version-file` | no | `.nvmrc` | Forwarded to `setup-yarn-project` |
| `registry-url` | no | `https://registry.npmjs.org` | npm registry |
| `source-glob` | no | `src/**/*.{ts,tsx}` | Passed to `prettier --check` |
| `package-manager` | no | `auto` | `auto` / `yarn` / `npm` |
| `legacy-peer-deps` | no | `false` | `npm ci --legacy-peer-deps` (npm only) |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `npm-token` | **yes** | NPM auth token (transitive deps may be private) |

```yaml
format:
  uses: agrippa-io/github-actions/.github/workflows/npm-format.yml@v1
  with:
    npm-scope: '@agrippa-io'
  secrets:
    npm-token: ${{ secrets.NPM_TOKEN }}
```

---

## `npm-lint.yml`

`eslint` with `--max-warnings` as a strict gate. Default invocation
(`eslint . --ext .ts,.tsx --max-warnings=0`) matches the convention across
agrippa-io node repos.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `npm-scope` | **yes** | — | npm scope |
| `node-version-file` | no | `.nvmrc` | Forwarded to `setup-yarn-project` |
| `registry-url` | no | `https://registry.npmjs.org` | npm registry |
| `lint-paths` | no | `. --ext .ts,.tsx` | Args after the eslint binary |
| `max-warnings` | no | `0` | Forwarded to `eslint --max-warnings`; `-1` disables the gate |
| `package-manager` | no | `auto` | `auto` / `yarn` / `npm` |
| `legacy-peer-deps` | no | `false` | `npm ci --legacy-peer-deps` (npm only) |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `npm-token` | **yes** | NPM auth token |

```yaml
lint:
  uses: agrippa-io/github-actions/.github/workflows/npm-lint.yml@v1
  with:
    npm-scope: '@agrippa-io'
  secrets:
    npm-token: ${{ secrets.NPM_TOKEN }}
```

---

## `npm-test.yml`

Run the test suite. Defaults to `vitest run --coverage`. Toggle
`with-playwright: true` for any project whose suite mounts browser tests
(Storybook addon-vitest, Playwright e2e, etc.) — that enables the
[`playwright-cached-chromium`](#playwright-cached-chromium) install before
the tests run.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `npm-scope` | **yes** | — | npm scope |
| `node-version-file` | no | `.nvmrc` | Forwarded to `setup-yarn-project` |
| `registry-url` | no | `https://registry.npmjs.org` | npm registry |
| `with-playwright` | no | `false` | Cache + install Playwright Chromium before tests |
| `test-command` | no | `vitest run --coverage` | Local binary + args (run via `yarn`/`npx`), **not** a script name. For jest/mocha pass e.g. `jest --coverage` |
| `package-manager` | no | `auto` | `auto` / `yarn` / `npm` |
| `legacy-peer-deps` | no | `false` | `npm ci --legacy-peer-deps` (npm only) |
| `with-postgres` | no | `false` | Start a throwaway Postgres for DB suites that don't use Testcontainers; exposes `DATABASE_URL=postgres://ci:ci@localhost:5432/ci` |
| `postgres-version` | no | `16-alpine` | Postgres image tag when `with-postgres` is true |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `npm-token` | **yes** | NPM auth token |

```yaml
test:
  uses: agrippa-io/github-actions/.github/workflows/npm-test.yml@v1
  with:
    npm-scope: '@agrippa-io'
    with-playwright: true
  secrets:
    npm-token: ${{ secrets.NPM_TOKEN }}
```

---

## `npm-build.yml`

`yarn build` (and optionally `yarn build:storybook`), with the build
output uploaded as a workflow artifact so downstream jobs can consume it
via `actions/download-artifact` instead of rebuilding.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `npm-scope` | **yes** | — | npm scope |
| `node-version-file` | no | `.nvmrc` | Forwarded to `setup-yarn-project` |
| `registry-url` | no | `https://registry.npmjs.org` | npm registry |
| `build-script` | no | `build` | package.json script that produces the artifact (`yarn <s>` / `npm run <s>`) |
| `with-storybook` | no | `false` | Also run the `build:storybook` script |
| `package-manager` | no | `auto` | `auto` / `yarn` / `npm` |
| `legacy-peer-deps` | no | `false` | `npm ci --legacy-peer-deps` (npm only) |
| `upload-artifact` | no | `true` | Upload `artifact-path` as a workflow artifact |
| `artifact-name` | no | `dist` | Artifact name (consumer can interpolate `${{ github.event.pull_request.head.sha }}` for traceability) |
| `artifact-path` | no | `dist/` | Path uploaded |
| `artifact-retention-days` | no | `7` | Days to retain the artifact |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `npm-token` | **yes** | NPM auth token |

```yaml
build:
  needs: [format, lint, test]
  uses: agrippa-io/github-actions/.github/workflows/npm-build.yml@v1
  with:
    npm-scope: '@agrippa-io'
    with-storybook: true
    artifact-name: dist-${{ github.event.pull_request.head.sha }}
  secrets:
    npm-token: ${{ secrets.NPM_TOKEN }}
```

---

## Full consumer example

A typical `ci.yml` for an npm package in this workspace:

```yaml
name: ci
on:
  pull_request:
    branches: [develop, 'release/**', main]
concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  format:
    uses: agrippa-io/github-actions/.github/workflows/npm-format.yml@v1
    with: { npm-scope: '@agrippa-io' }
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  lint:
    uses: agrippa-io/github-actions/.github/workflows/npm-lint.yml@v1
    with: { npm-scope: '@agrippa-io' }
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  test:
    uses: agrippa-io/github-actions/.github/workflows/npm-test.yml@v1
    with: { npm-scope: '@agrippa-io', with-playwright: true }
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  build:
    needs: [format, lint, test]
    uses: agrippa-io/github-actions/.github/workflows/npm-build.yml@v1
    with:
      npm-scope: '@agrippa-io'
      with-storybook: true
      artifact-name: dist-${{ github.event.pull_request.head.sha }}
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  publish-canary:
    needs: build
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    permissions: { contents: read, pull-requests: write }
    steps:
      # ... (canary publish stays in the consumer because the PR-comment
      # body and install snippet are package-specific)
```

`format` / `lint` / `test` run in parallel; `build` gates on all three;
`publish-canary` gates on `build`.

---

## `npm-publish-prerelease.yml`

Publish a prerelease build to npm under a configurable dist-tag. One
workflow covers all three prerelease patterns:

| Pattern | dist-tag | suffix template | Where this fires |
| ------- | -------- | --------------- | ---------------- |
| canary  | `canary` | `canary.<short-sha>` | PR validation (`ci.yml`) |
| dev     | `dev`    | `dev.<pr-number>.<short-sha>` | push to `develop` |
| staging | `staging` | `rc.<run-number>` | push to `release/**` |

The suffix is caller-supplied — the workflow doesn't look up PR numbers or
SHAs itself, because the lookup logic differs per pattern (dev needs the
PR number for the commit; staging just uses `github.run_number`). Callers
that need a PR-number suffix add a small pre-job that runs
`repos.listPullRequestsAssociatedWithCommit` and threads the result into
`version-suffix`.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `npm-scope` | **yes** | — | npm scope |
| `node-version-file` | no | `.nvmrc` | Forwarded to `setup-yarn-project` |
| `registry-url` | no | `https://registry.npmjs.org` | npm registry |
| `dist-tag` | **yes** | — | `canary`, `dev`, `staging`, or any other tag |
| `version-suffix` | **yes** | — | Appended after `-` to the base version |
| `access` | no | `restricted` | Passed to `npm publish --access` |
| `ref` | no | (workflow trigger ref) | Optional explicit ref to check out (e.g. the PR head SHA for canary) |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `npm-token` | **yes** | NPM auth token |

| Output | Description |
| ------ | ----------- |
| `version` | Full prerelease version that was published |

```yaml
# Staging example — the easy case, no PR lookup needed.
publish-staging:
  if: startsWith(github.ref, 'refs/heads/release/')
  needs: build
  uses: agrippa-io/github-actions/.github/workflows/npm-publish-prerelease.yml@v1
  with:
    npm-scope: '@agrippa-io'
    dist-tag: staging
    version-suffix: rc.${{ github.run_number }}
  secrets:
    npm-token: ${{ secrets.NPM_TOKEN }}
```

```yaml
# Dev example — caller looks up the PR number first.
compute-dev-suffix:
  if: github.ref == 'refs/heads/develop'
  runs-on: ubuntu-latest
  outputs:
    suffix: ${{ steps.s.outputs.suffix }}
  steps:
    - uses: actions/github-script@v7
      id: s
      with:
        script: |
          const { data } = await github.rest.repos.listPullRequestsAssociatedWithCommit({
            owner: context.repo.owner,
            repo: context.repo.repo,
            commit_sha: context.sha,
          })
          const pr = data[0]?.number ?? 0
          const sha = (data[0]?.merge_commit_sha ?? context.sha).slice(0, 7)
          core.setOutput('suffix', `dev.${pr}.${sha}`)

publish-dev:
  needs: [build, compute-dev-suffix]
  uses: agrippa-io/github-actions/.github/workflows/npm-publish-prerelease.yml@v1
  with:
    npm-scope: '@agrippa-io'
    dist-tag: dev
    version-suffix: ${{ needs.compute-dev-suffix.outputs.suffix }}
  secrets:
    npm-token: ${{ secrets.NPM_TOKEN }}
```

---

## `npm-publish-latest.yml`

Production publish. Reads version from `package.json` (the bump arrived
via the squash-merge of the release PR — see
[`npm-release-stage.yml`](#npm-release-stageyml)). Publishes with dist-tag
`latest`, then creates a `vX.Y.Z` git tag remotely via
`repos.createRelease` pinned to the triggering commit. No `git push --tag`
to the protected branch.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `npm-scope` | **yes** | — | npm scope |
| `node-version-file` | no | `.nvmrc` | Forwarded to `setup-yarn-project` |
| `registry-url` | no | `https://registry.npmjs.org` | npm registry |
| `access` | no | `restricted` | Passed to `npm publish --access` |
| `generate-release-notes` | no | `true` | Auto-generate notes from PRs since previous tag |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `npm-token` | **yes** | NPM auth token |

| Output | Description |
| ------ | ----------- |
| `version` | Version that was published |
| `tag` | Git tag created (e.g. `v0.1.0`) |
| `release-url` | HTML URL of the GitHub Release |

```yaml
publish-prod:
  if: github.ref == 'refs/heads/main'
  needs: build
  uses: agrippa-io/github-actions/.github/workflows/npm-publish-latest.yml@v1
  with:
    npm-scope: '@agrippa-io'
  secrets:
    npm-token: ${{ secrets.NPM_TOKEN }}
```

The workflow internally declares `permissions: contents: write` + `id-token: write` on its own job, so the caller does not need to set those.

---

## `npm-release-stage.yml`

Operator-triggered release branch cut. Validates the semver input, cuts
`release/X.Y.Z` from the source branch, bumps `package.json#version` via
the GitHub contents API (verified-signed commit by `github-actions[bot]`,
works under "require signed commits" branch protection), and opens a
draft promotion PR.

Designed for `workflow_dispatch`-style invocation from the consumer (the
operator types the version into the consumer's `release-stage.yml`, which
in turn calls this).

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `version` | **yes** | — | Strict semver `x.y.z` (prerelease suffixes rejected) |
| `source-branch` | no | `develop` | Branch the release is cut from |
| `target-branch` | no | `main` | Branch the release PR will target |
| `draft` | no | `true` | Open the promotion PR as a draft |
| `pr-title` | no | `chore(release): <version>` | Override the title |
| `pr-body` | no | (sensible default) | Override the body; supports `{version}`, `{branch}`, `{source}`, `{target}` substitutions |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `release-token` | **yes** | PAT with `Contents: read and write` — pushes from this token trigger downstream workflows on the release branch |

| Output | Description |
| ------ | ----------- |
| `branch` | Name of the release branch that was cut |
| `pr-number` | Number of the promotion PR |

```yaml
on:
  workflow_dispatch:
    inputs:
      version: { type: string, required: true }

jobs:
  cut-release-branch:
    uses: agrippa-io/github-actions/.github/workflows/npm-release-stage.yml@v1
    with:
      version: ${{ inputs.version }}
    secrets:
      release-token: ${{ secrets.RELEASE_TOKEN }}
```

---

## `gitflow-sync-back.yml`

After a release lands on the release line (default `main`), open a
back-merge PR to the integration line (default `develop`) so the version
bump and any stabilization fixes flow downstream. Generic gitflow
concern — not npm-specific.

If the source is already in sync (0 commits ahead), the workflow is a
no-op and prints a summary. If a sync branch for the version already
exists on origin (an earlier run still has the PR in flight), the
workflow skips creation rather than opening a duplicate.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `from` | no | `main` | Source branch (just-merged production) |
| `to` | no | `develop` | Target integration branch |
| `version` | no | `package.json#version` on `from` | Label embedded in the sync branch + PR title |
| `branch-prefix` | no | `sync` | Prefix for the sync branch |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `release-token` | **yes** | PAT with `Contents: read and write` |

```yaml
sync-develop:
  if: github.ref == 'refs/heads/main'
  needs: publish-prod
  uses: agrippa-io/github-actions/.github/workflows/gitflow-sync-back.yml@v1
  with:
    version: ${{ needs.publish-prod.outputs.version }}
  secrets:
    release-token: ${{ secrets.RELEASE_TOKEN }}
```
