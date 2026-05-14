# `aws/*` — AWS-flavored reusable workflows

AWS-related reusable workflows live alongside the npm ones at
[`../.github/workflows/`](../.github/workflows/) because GitHub requires
reusable workflows live at that path. This README documents them.

| Reusable workflow | Purpose |
| ----------------- | ------- |
| [`docker-publish-ecr.yml`](#docker-publish-ecryml) | Build a Docker image and push it to AWS ECR with OIDC auth + BuildKit caching |

## Pinning

```yaml
- uses: agrippa-io/github-actions/.github/workflows/docker-publish-ecr.yml@v1
```

Same versioning policy as the npm workflows — pin to `@v1` (floating) for
routine consumption, `@v1.M.P` for reproducibility.

---

## `docker-publish-ecr.yml`

Build a Docker image and push it to AWS ECR. Configures AWS credentials
via GitHub OIDC (no long-lived AWS keys), logs in to ECR, then uses
BuildKit (`docker/setup-buildx-action@v3`) and `docker/build-push-action@v5`
to build and push. Pushes two tags by default — an immutable `vX.Y.Z`
mirror of the npm tag plus a floating `latest`. GitHub Actions cache is
wired in so dependency layers reuse across runs.

Optional BuildKit secret mount: pass `buildkit-secret-name` +
`buildkit-secret-value` to inject a secret (typically `NPM_TOKEN` for
private-registry installs at build time) that is mounted at
`/run/secrets/<name>` for the duration of a `RUN` and never lands in any
image layer. See the consumer's `Dockerfile` for the
`RUN --mount=type=secret,id=<name> ...` pattern.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `registry-url` | **yes** | — | Full ECR repository URL (`<account>.dkr.ecr.<region>.amazonaws.com/<repo>`) |
| `aws-region` | **yes** | — | AWS region for ECR |
| `tag` | **yes** | — | Immutable tag (e.g. `v0.1.0`) — typically `npm-publish-latest`'s `tag` output |
| `also-latest` | no | `true` | Also push a floating `latest` tag |
| `context` | no | `.` | Docker build context |
| `dockerfile` | no | `Dockerfile` | Path to the Dockerfile relative to context |
| `buildkit-secret-name` | no | `npm_token` | Name used to expose the secret to BuildKit (referenced inside the Dockerfile via `--mount=type=secret,id=<name>`); set to empty to disable |

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `aws-role-arn` | **yes** | ARN of the IAM role to assume via OIDC |
| `buildkit-secret-value` | conditional | Required when `buildkit-secret-name` is non-empty |

```yaml
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
```

The calling job's `permissions:` block does **not** need `id-token: write` —
this reusable workflow declares it on its own job. The consumer's
permission is whatever's needed by other jobs in their workflow.

### AWS-side prerequisites

The IAM role referenced by `aws-role-arn` must trust the GitHub OIDC
provider scoped to the consumer's repo (and typically a specific ref):

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<owner>/<consumer>:ref:refs/heads/main" }
  }
}
```

The role's permission policy needs the standard ECR push set:
`ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`,
`ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`,
`ecr:PutImage` — scoped to the target repository ARN.

The ECR repository must already exist; ECR does not auto-create on first
push. Tag immutability (`--image-tag-mutability IMMUTABLE`) is recommended
so the `vX.Y.Z` tag cannot be overwritten while `latest` rotates.
