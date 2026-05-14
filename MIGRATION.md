# Migration playbook — adopting `agrippa-io/github-actions` in a consumer repo

This is the per-repo recipe for adopting the shared workflows. Pin to
[`@v1`](https://github.com/agrippa-io/github-actions/releases) for routine
consumption; use exact tags (`@v1.2.0`) when reproducibility matters.

Three consumer archetypes cover almost everything in the workspace:

1. **Published npm package** (a `@agrippa-io/*` library) — full CI + release flow.
2. **Frontend / unpublished node project** (Vite app, e2e harness) — CI gates only, no publish.
3. **Docker-only service** (a node service deployed as a container) — CI gates + Docker push, no npm publish.

For each archetype, copy the matching template into the consumer's
`.github/workflows/`, adjust the inputs to the project's conventions, and
follow the per-archetype notes below.

`apps/react-components` (the reference implementation) is archetype 1 and
exercises every primitive in the shared repo. When in doubt, look at how
react-components does it.

## Prerequisites

Each consumer needs:

- **Repo secrets**
  - `NPM_TOKEN` — npm automation token with publish access to the scope (archetypes 1, 2, 3 if private deps).
  - `RELEASE_TOKEN` — GitHub PAT with `Contents: read and write`. Required for archetype 1 (the `release-stage` workflow pushes the release branch + commits the package.json bump via the contents API). Optional for archetypes 2 and 3.
  - `AWS_DEPLOY_ROLE_ARN` — IAM role ARN trusted for OIDC. Required for archetypes that push to ECR.
- **GitHub Environments** (`dev`, `staging`, `prod`) — gate publishes with manual approvals + environment-scoped secrets, only needed for archetype 1.
- **Branch protection on `main`** — the shared release flow does NOT require any bypass; the version bump arrives via the squash-merge of the release PR, and tags are created remotely via `repos.createRelease`. So `main` can be as strict as you like (required reviews, signed commits, linear history) without conflicts.
- **GitHub Actions allow-list** at the org level — `agrippa-io/github-actions` is public, so no `access_level` flips are required. Just confirm org Settings → Actions → "Allow all actions and reusable workflows" or that this repo is on the allow-list.

---

## Archetype 1: published npm package

**Example:** `apps/react-components` ([live ci.yml](https://github.com/agrippa-io/react-components/blob/develop/.github/workflows/ci.yml)).

### `.github/workflows/ci.yml`

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
    with:
      npm-scope: '@agrippa-io'
      with-playwright: true   # only if your tests mount a real browser
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  build:
    needs: [format, lint, test]
    uses: agrippa-io/github-actions/.github/workflows/npm-build.yml@v1
    with:
      npm-scope: '@agrippa-io'
      with-storybook: true    # only if you publish a Storybook static site
      artifact-name: dist-${{ github.event.pull_request.head.sha }}
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  publish-canary:
    needs: build
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    permissions: { contents: read, pull-requests: write }
    steps:
      # Canary publish stays inline — the PR-comment install snippet is
      # package-specific. See react-components ci.yml for the pattern.
```

### `.github/workflows/release.yml`

```yaml
name: release
on:
  push: { branches: [develop, 'release/**', main] }
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  # Re-validate on every push (the same 4 jobs as ci.yml).
  format: { uses: agrippa-io/github-actions/.github/workflows/npm-format.yml@v1, with: { npm-scope: '@agrippa-io' }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }
  lint:   { uses: agrippa-io/github-actions/.github/workflows/npm-lint.yml@v1,   with: { npm-scope: '@agrippa-io' }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }
  test:   { uses: agrippa-io/github-actions/.github/workflows/npm-test.yml@v1,   with: { npm-scope: '@agrippa-io', with-playwright: true }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }
  build:  { needs: [format, lint, test], uses: agrippa-io/github-actions/.github/workflows/npm-build.yml@v1, with: { npm-scope: '@agrippa-io', with-storybook: true }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }

  # dev publishes need a PR-number lookup.
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
    if: github.ref == 'refs/heads/develop'
    needs: [build, compute-dev-suffix]
    uses: agrippa-io/github-actions/.github/workflows/npm-publish-prerelease.yml@v1
    with:
      npm-scope: '@agrippa-io'
      dist-tag: dev
      version-suffix: ${{ needs.compute-dev-suffix.outputs.suffix }}
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  publish-staging:
    if: startsWith(github.ref, 'refs/heads/release/')
    needs: build
    uses: agrippa-io/github-actions/.github/workflows/npm-publish-prerelease.yml@v1
    with:
      npm-scope: '@agrippa-io'
      dist-tag: staging
      version-suffix: rc.${{ github.run_number }}
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  publish-prod:
    if: github.ref == 'refs/heads/main'
    needs: build
    uses: agrippa-io/github-actions/.github/workflows/npm-publish-latest.yml@v1
    with: { npm-scope: '@agrippa-io' }
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  # Optional: also push a Docker image (drop this job if you don't ship Docker).
  publish-docker:
    if: github.ref == 'refs/heads/main'
    needs: publish-prod
    uses: agrippa-io/github-actions/.github/workflows/docker-publish-ecr.yml@v1
    with:
      registry-url: ${{ vars.URL_DOCKER_REGISTRY }}
      aws-region: us-west-1
      tag: ${{ needs.publish-prod.outputs.tag }}
    secrets:
      aws-role-arn: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
      buildkit-secret-value: ${{ secrets.NPM_TOKEN }}

  sync-develop:
    if: github.ref == 'refs/heads/main'
    needs: publish-prod
    uses: agrippa-io/github-actions/.github/workflows/gitflow-sync-back.yml@v1
    with: { version: '${{ needs.publish-prod.outputs.version }}' }
    secrets: { release-token: '${{ secrets.RELEASE_TOKEN }}' }
```

### `.github/workflows/release-stage.yml`

```yaml
name: release-stage
on:
  workflow_dispatch:
    inputs:
      version: { description: 'Release version (semver, e.g. 0.1.0)', required: true, type: string }
jobs:
  cut-release-branch:
    uses: agrippa-io/github-actions/.github/workflows/npm-release-stage.yml@v1
    with: { version: '${{ inputs.version }}' }
    secrets: { release-token: '${{ secrets.RELEASE_TOKEN }}' }
```

### Things to adjust per-repo

- **`npm-scope`** — defaults all use `@agrippa-io`; change if the package is on a different scope.
- **`with-playwright`** in `npm-test` — set `true` only if the test suite mounts browser tests (Storybook addon-vitest, Playwright e2e). Default `false` avoids the ~30s install on every CI run.
- **`with-storybook`** in `npm-build` — set `true` only if you publish a Storybook static site. Most packages don't.
- **`max-warnings`** in `npm-lint` — defaults to `0` (strict gate). Set to `-1` to disable while migrating a noisy codebase.
- **`source-glob`** in `npm-format` — adjust if your prettier convention differs from `src/**/*.{ts,tsx}`.
- **`test-command`** in `npm-test` — defaults to `vitest run --coverage`. For mocha / jest, override (e.g. `'test'` to use the `yarn test` script).
- **Drop `publish-docker`** entirely if you don't ship Docker.

---

## Archetype 2: frontend / unpublished node project

**Example:** `apps/react-stockmarket` (no tests, no publish, just lint + build).

### `.github/workflows/ci.yml`

```yaml
name: ci
on:
  pull_request:
    branches: [main]
concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    uses: agrippa-io/github-actions/.github/workflows/npm-lint.yml@v1
    with:
      npm-scope: '@agrippa-io'
      lint-paths: '.'    # adjust if your `yarn lint` script differs
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }

  build:
    needs: lint
    uses: agrippa-io/github-actions/.github/workflows/npm-build.yml@v1
    with:
      npm-scope: '@agrippa-io'
      upload-artifact: false    # uploaded `dist/` not useful for non-publishing apps
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }
```

### Things to adjust per-repo

- **Skip `format`/`test`** if the project doesn't have prettier / a test suite. Don't add them just to satisfy a template.
- **`lint-paths`** — adapt to the project's eslint invocation. Vite-scaffolded apps usually take `'.'` with no `--ext` flag.
- **`upload-artifact: false`** — `dist/` isn't useful as a CI artifact for non-publishing apps. (If you deploy from CI, separately push it to your hosting provider.)
- **Drop release.yml entirely** unless you have a deploy step worth automating. Vite-style "preview" can run on local dev only.

---

## Archetype 3: Docker-only service

**Example:** `apps/node-service-gateway` (node service deployed as ECR image, no npm publish).

### `.github/workflows/ci.yml`

```yaml
name: ci
on:
  pull_request:
    branches: [main]
jobs:
  format: { uses: agrippa-io/github-actions/.github/workflows/npm-format.yml@v1, with: { npm-scope: '@agrippa-io' }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }
  lint:   { uses: agrippa-io/github-actions/.github/workflows/npm-lint.yml@v1,   with: { npm-scope: '@agrippa-io' }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }
  test:   { uses: agrippa-io/github-actions/.github/workflows/npm-test.yml@v1,   with: { npm-scope: '@agrippa-io' }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }
  build:
    needs: [format, lint, test]
    uses: agrippa-io/github-actions/.github/workflows/npm-build.yml@v1
    with:
      npm-scope: '@agrippa-io'
      upload-artifact: false
    secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' }
```

### `.github/workflows/release.yml`

Two flavors. **Simple** (one job; lint+test+build happens implicitly inside the Docker build):

```yaml
name: release
on:
  push: { branches: [main] }
jobs:
  release:
    uses: agrippa-io/github-actions/.github/workflows/docker-only-release.yml@v1
    with:
      registry-url: ${{ vars.URL_DOCKER_REGISTRY }}
      aws-region: us-west-1
    secrets:
      aws-role-arn: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
```

**Gated** (validate first, then push):

```yaml
name: release
on:
  push: { branches: [main] }
jobs:
  format: { uses: agrippa-io/github-actions/.github/workflows/npm-format.yml@v1, with: { npm-scope: '@agrippa-io' }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }
  lint:   { uses: agrippa-io/github-actions/.github/workflows/npm-lint.yml@v1,   with: { npm-scope: '@agrippa-io' }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }
  test:   { uses: agrippa-io/github-actions/.github/workflows/npm-test.yml@v1,   with: { npm-scope: '@agrippa-io' }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }
  build:  { needs: [format, lint, test], uses: agrippa-io/github-actions/.github/workflows/npm-build.yml@v1, with: { npm-scope: '@agrippa-io', upload-artifact: false }, secrets: { npm-token: '${{ secrets.NPM_TOKEN }}' } }

  publish-docker:
    needs: build
    uses: agrippa-io/github-actions/.github/workflows/docker-only-release.yml@v1
    with:
      registry-url: ${{ vars.URL_DOCKER_REGISTRY }}
      aws-region: us-west-1
    secrets:
      aws-role-arn: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
```

### Things to adjust per-repo

- **No `release-stage.yml` needed** — there's no semver version to track. Each push to main is its own release tagged by short SHA.
- **`URL_DOCKER_REGISTRY`** must be set as a repo or environment variable.
- **AWS role trust policy** must include the consumer repo's identity. See [`aws/README.md`](./aws/README.md#aws-side-prerequisites).
- **Tag immutability on the ECR repo** is recommended so the short-SHA tags can't be overwritten.

---

## Migrating an existing repo

For repos that already have workflows:

1. Open a feature branch and **add the new files alongside** the old ones (e.g. name them `ci.new.yml`). Keep both in place so you can run them in parallel for a few PRs and compare outcomes.
2. Once the new workflow's been green across 3-4 PRs covering different change types (lint failure, test failure, all-pass), **delete the old workflow file in a follow-up PR**.
3. **Update `RELEASE.md`** (if the consumer has one) to reflect the new setup. Point at the shared workflows' README for inputs/outputs.

For repos that have **no workflows yet**:

1. Pick the matching archetype above.
2. Drop the file in `.github/workflows/`.
3. Add the required repo secrets (see Prerequisites).
4. Open a draft PR and watch the run. Iterate on inputs.
5. Mark ready + merge.

## Common gotchas

- **`npm-token` is required by setup-yarn-project** even for installs from the public registry — that's because `setup-node` always writes the `.npmrc` token line when `scope` is set, and yarn errors if `NODE_AUTH_TOKEN` is empty. Just pass `secrets.NPM_TOKEN` and forget about it.
- **`with-storybook: true`** requires the repo to have a `build:storybook` script. Without it, the build step fails with `script not found: build:storybook`.
- **`with-playwright: true`** adds ~30s of install time on a cold cache, ~5s warm. Don't enable unless tests actually mount a browser.
- **The `compute-dev-suffix` action needs `permissions: pull-requests: read`** on the calling job — the lookup is a REST call that requires that scope.
- **Reusable workflows can't use `secrets: inherit` if they declare specific `secrets:` blocks** — declare each secret explicitly when calling, or use `inherit` if you control both ends.
