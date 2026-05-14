# `agrippa-io/github-actions`

Reusable GitHub Actions and reusable workflows for the Agrippa workspace.
Consumed by sibling repos (apps, packages) under the same org.

## Layout

```
github-actions/
├── npm/              # Composite actions for npm/yarn-published projects
│   ├── actions/
│   │   ├── setup-yarn-project/
│   │   ├── bump-package-json/
│   │   ├── compute-prerelease-version/
│   │   ├── playwright-cached-chromium/
│   │   └── create-release-and-tag/
│   └── README.md     # Action-by-action reference + usage examples
├── aws/              # (Reserved) AWS/ECR/IAM-related actions and jobs
└── .github/
    └── workflows/    # Internal CI for this repo + reusable workflows for consumers
```

Domain-grouped at the top level (`npm/`, `aws/`) so the search-by-concept
case stays cheap. Within each group, the `actions/` subdirectory holds
composite actions; reusable workflows (when added) live at
`.github/workflows/` because GitHub requires that path.

## Versioning

Consumers pin by git tag, never by branch. Cut a major-version tag (`v1`)
that floats forward as breaking changes are absorbed, plus exact-version
tags (`v1.2.0`) for consumers that need fixed pins. Both forms are valid:

```yaml
- uses: agrippa-io/github-actions/npm/actions/setup-yarn-project@v1
- uses: agrippa-io/github-actions/npm/actions/setup-yarn-project@v1.2.0
```

The internal CI workflow under `.github/workflows/` should run on every PR
so regressions are caught before a tag is cut.

## Adding a new action

1. Decide its domain. New domains get a top-level directory (mirrors `npm/`,
   `aws/`).
2. Put the action at `<domain>/actions/<kebab-case-name>/action.yml`.
3. For composite actions, declare `runs.using: composite` with a `steps:`
   list. For JS actions, see `src/actions/` for the wrapper convention.
4. Update the domain's `README.md` with: purpose, when to run, the input
   table, the output table, and a minimal usage example.
5. Open a PR. Once merged, retag (`v1` floating + a new exact tag).

## Adding a new reusable workflow

1. Put it at `.github/workflows/<name>.yml` — GitHub requires this exact
   path for reusable workflows.
2. Declare `on.workflow_call.inputs` / `secrets` explicitly. Avoid `secrets:
   inherit` semantics inside the reusable workflow — be explicit about what
   you require.
3. Reference composite actions from `<domain>/actions/...` rather than
   re-implementing their logic. The reusable workflow's job is
   orchestration, not implementation.

See [`npm/README.md`](./npm/README.md) for the action reference,
[`aws/README.md`](./aws/README.md) for the Docker/ECR workflows, and
[`MIGRATION.md`](./MIGRATION.md) for the per-consumer playbook (how to
wire ci.yml + release.yml in a new repo by archetype: npm package /
frontend app / docker-only service).
