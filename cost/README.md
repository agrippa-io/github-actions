# cost/

Actions for the **Cost Planner** (`node-service-cost-planner`, epic cost-planner-0).

## `cost-inventory` — sync the planner's inventory on push

After a repo's CI passes on a push, tell the planner that the repo changed:
`POST <planner-url>/webhooks/inventory-sync` with `Authorization: Bearer <token>`. The planner
then re-reads every repo's `deploy.yaml`, `registry.json`, `environments/*.yaml` and chart values
into its architecture model and emits `cost.inventory.synced` (cost-planner-0 2.4, D2). It also
syncs nightly; this step makes it follow pushes.

**Opt-in and safe for every repo's CI.** No URL or no token: a notice, outcome `skipped`, the
step succeeds. A refused (401, 503, 5xx) or unreachable planner: a warning, outcome `failed`, the
step still succeeds, unless `strict: true`.

### Wire a repo: the reusable workflow

```yaml
# .github/workflows/ci.yml, after the ci-ok gate
  cost-inventory:
    needs: ci-ok
    if: github.event_name == 'push'
    uses: agrippa-io/github-actions/.github/workflows/cost-inventory.yml@v1.14.0
    secrets:
      cost-planner-token: ${{ secrets.COST_PLANNER_TRIGGER_TOKEN }}
```

| Setting | Where | What |
|---|---|---|
| `vars.COST_PLANNER_URL` | org (or repo) variable | planner base URL, e.g. `https://api.<env>/cost-planner/v1` |
| `secrets.COST_PLANNER_TRIGGER_TOKEN` | org (or repo) secret | the planner's `INVENTORY_SYNC_TRIGGER_TOKEN` |

| Workflow input | Default | |
|---|---|---|
| `planner-url` | `vars.COST_PLANNER_URL` | overrides the variable |
| `strict` | `false` | fail the job when the planner refuses or cannot be reached |
| `dry-run` | `false` | print the request, send nothing |

Output `outcome`: `accepted`, `skipped`, `dry-run` or `failed`.

### The action

```yaml
- uses: agrippa-io/github-actions/cost/actions/cost-inventory@v1.14.0
  with:
    planner-url: ${{ vars.COST_PLANNER_URL }}
    token: ${{ secrets.COST_PLANNER_TRIGGER_TOKEN }}
```

| Input | Default | |
|---|---|---|
| `planner-url` | `''` (skip) | planner base URL |
| `token` | `''` (skip) | the trigger token (masked) |
| `repo` / `ref` / `sha` | `GITHUB_REPOSITORY` / `GITHUB_REF_NAME` / `GITHUB_SHA` | what changed (logged by the planner; every sync is a full read) |
| `strict` | `false` | `true` fails on 401 / 503 / 5xx / unreachable |
| `dry-run` | `false` | print the request without the token, send nothing |

| Output | |
|---|---|
| `outcome` | `accepted`, `skipped`, `dry-run` or `failed` |
| `joined` | `true` when the planner was already syncing and this push joined it |
| `status` | HTTP status, empty when nothing was sent |

Tests: `cost/actions/cost-inventory/test/run.sh` runs `trigger.sh` against a stub planner
(`test/stub_server.py`); `.github/workflows/test-cost-inventory.yml` runs it, the action itself,
and the reusable workflow from each tag.
