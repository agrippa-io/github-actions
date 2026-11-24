# `security/*` — secret scanning

| Piece | Purpose |
| ----- | ------- |
| [`security/actions/gitleaks`](./actions/gitleaks/action.yml) | Composite action: installs a pinned, SHA-256-verified gitleaks binary and scans the commit range of the current event |
| [`.github/workflows/gitleaks.yml`](../.github/workflows/gitleaks.yml) | Reusable workflow: full-history checkout + the action, as one `gitleaks` job |

## Wiring it into a repo's CI

Add a job to `.github/workflows/ci.yml` and put it in the `ci-ok` gate:

```yaml
jobs:
  gitleaks:
    uses: agrippa-io/github-actions/.github/workflows/gitleaks.yml@v1

  ci-ok:
    needs: [lint, test, build, gitleaks]   # ...and check needs.gitleaks.result
```

## What it scans

| Event | Range |
| ----- | ----- |
| `pull_request` | `base.sha..head.sha` — the PR's commits |
| `merge_group` | `base_sha..head_sha` |
| `push` | `before..after`; a new branch scans `origin/<default>..after`; a deletion scans nothing |
| anything else (`workflow_dispatch`, `schedule`) | full history (`--all`) |

Only new commits are scanned on PRs and pushes, so secrets already in history
don't fail every build. They still need rotating: run a full scan locally
(`gitleaks git --log-opts=--all --redact .`) and treat every hit as a
credential to revoke. Pass `log-opts: --all` to the workflow for a CI full scan.

## Inputs

| Input | Default | Notes |
| ----- | ------- | ----- |
| `gitleaks-version` (workflow) / `version` (action) | `8.30.1` | Bump together with the action's `sha256-linux-x64` / `sha256-linux-arm64` (from the release's `checksums.txt`) |
| `log-opts` | event range | Override the `git log` range |
| `config` | — | gitleaks picks up the repo's `.gitleaks.toml` on its own |

## False positives

Confirm the value is not a credential (test fixture, documentation example,
public sample), then add the finding's `Fingerprint` (printed in the job's
annotations, `<commit>:<file>:<rule>:<line>`) to `.gitleaksignore` at the repo
root, with a comment saying why. Never allowlist a real secret: rotate it.

## Pre-commit

Each repo carries a `.pre-commit-config.yaml` that runs the upstream gitleaks
hook on staged changes:

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
```

Install it once per clone with `pre-commit install` (agrippa-stack's
`npm run hooks:install` does every repo in the workspace). Repos that use
husky run `gitleaks git --pre-commit --staged --redact` from `.husky/pre-commit`
instead.
