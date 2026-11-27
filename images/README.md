# `images/*` — container image workflows

The reusable workflow lives at
[`../.github/workflows/image-build.yml`](../.github/workflows/image-build.yml)
(GitHub requires that path). This README documents it.

| Reusable workflow | Purpose |
| ----------------- | ------- |
| [`image-build.yml`](#image-buildyml) | Multi-arch build, Trivy scan, push to GHCR by digest, cosign keyless signature, `image-built` dispatch to GitOps |

The older ECR workflows (`docker-publish-ecr.yml`, `docker-only-release.yml`)
are documented in [`../aws/README.md`](../aws/README.md). New images use
`image-build.yml`.

## Pinning

```yaml
uses: agrippa-io/github-actions/.github/workflows/image-build.yml@v1
```

---

## `image-build.yml`

What one run does:

1. **Scan before push.** Builds `linux/amd64` into the runner's daemon and runs
   Trivy (`aquasecurity/trivy-action`, pinned by commit). A finding at
   `scan-severity` (default `CRITICAL`, fixable only) fails the job and nothing
   is pushed. Accepted CVEs go in a `.trivyignore` (`trivyignores` input), each
   with a reason.
2. **Multi-arch push.** Builds every platform in `platforms` (default
   `linux/amd64,linux/arm64`, QEMU for the foreign one) and pushes the image
   index to `ghcr.io/<owner>/<repo>` with tag `sha-<7>` (or `tag`) plus any
   `extra-tags`. Layers come from the GHA cache the scan build filled.
3. **Keyless signature.** `cosign sign` signs the pushed digest with a
   certificate minted from the run's GitHub OIDC token (Fulcio) and logged in
   Rekor; no key exists to store or rotate. The signature is verified in the
   same step.
4. **GitOps hand-off.** With a `workload` and a `dispatch-token`, sends
   `repository_dispatch` `image-built` to `agrippa-io/agrippa-stack` with
   `client_payload` `{workload, digest, tag, source}` (`source` = this run's
   URL). agrippa-stack's `gitops-bump` workflow pins the digest in
   `deploy/envs/e2e/images.yaml` by pull request. Without a token it logs a
   notice and succeeds, so the workflow works before the token exists.

With `push: false` (pull requests) only step 1 runs.

### ECR mirror (off until AWS is set up)

agrippa-stack's container registry router (`deploy/registries.yaml`, DC-4 step
4.4.1) can pull an environment from AWS ECR instead of GHCR. For that, every
image must also be in ECR with the **same digest** and its own signature, so
the workflow can mirror: when `ecr-mirror` or the org variable
`AGRIPPA_ECR_MIRROR` holds an ECR prefix
(`<account>.dkr.ecr.<region>.amazonaws.com/<namespace>`), the job

1. assumes the role in `ecr-role-arn` / the variable `AWS_ECR_ROLE_ARN` with
   this run's GitHub OIDC token (`aws-actions/configure-aws-credentials`; the
   job already has `id-token: write`), so there are no AWS keys, and logs in to
   ECR (`aws-actions/amazon-ecr-login`);
2. pushes `<prefix>/<image-name>` with the same tags **in the same build** as
   GHCR, so the image index (and its digest) is byte-identical in both;
3. cosign-signs and verifies the ECR ref too (signatures live per registry;
   Kyverno checks the one in the registry it pulls from).

With neither set, nothing changes (no AWS step runs). `ecr-mirror: none` turns
the mirror off for one caller (the selftest). The ECR repository
`<namespace>/<image-name>` must exist first: ECR does not create repositories
on push. The one-time AWS setup (OIDC provider, role, policies, repositories)
is in agrippa-stack `deploy/REGISTRIES.md`.

Deploys pin `outputs.ref` (`<image>@sha256:…`); tags are for people reading
the registry, and the workflow never pushes `latest` unless a caller asks
for it in `extra-tags`.

### Inputs

| Input | Default | Description |
| ----- | ------- | ----------- |
| `image-name` | calling repo name | Image name under the owner |
| `registry` | `ghcr.io` | Registry host |
| `registry-owner` | calling repo owner | Registry namespace (lowercased) |
| `context` | `.` | Build context |
| `dockerfile` | `Dockerfile` | Dockerfile path relative to `context` |
| `platforms` | `linux/amd64,linux/arm64` | Platforms to push |
| `tag` | `sha-<7-char commit>` | Tag pushed with the digest |
| `extra-tags` | — | More tags, one per line |
| `build-args` | — | `KEY=value`, one per line |
| `buildkit-secret-name` | — | BuildKit secret id (`RUN --mount=type=secret,id=<name>`); value from the `buildkit-secret-value` secret |
| `push` | `true` | `false` = build and scan only |
| `scan-severity` | `CRITICAL` | Severities that fail the build |
| `scan-ignore-unfixed` | `true` | Skip findings with no fix yet |
| `trivyignores` | — | Path to a `.trivyignore` in the calling repo |
| `verify-identity-regexp` | this workflow's URL | Identity the fresh signature must carry |
| `workload` | — | agrippa-stack `registry.json` workload name; empty skips the dispatch |
| `dispatch-repository` | `agrippa-io/agrippa-stack` | Dispatch target |
| `dispatch-event` | `image-built` | Dispatch event type |
| `ecr-mirror` | `vars.AGRIPPA_ECR_MIRROR`, else none | ECR prefix to mirror to; `none` = off |
| `ecr-region` | `vars.AGRIPPA_ECR_REGION`, else from `ecr-mirror` | AWS region of the mirror |
| `ecr-role-arn` | `vars.AWS_ECR_ROLE_ARN` | IAM role assumed with GitHub OIDC to push (an ARN, not a secret) |

| Secret | Description |
| ------ | ----------- |
| `buildkit-secret-value` | Value of the BuildKit secret (typically `NPM_TOKEN`) |
| `dispatch-token` | Token with contents write on `dispatch-repository`; absent → no dispatch |

| Output | Description |
| ------ | ----------- |
| `image` | `ghcr.io/<owner>/<name>` |
| `tag` | Tag pushed |
| `digest` | `sha256:…` of the image index (empty without push) |
| `ref` | `<image>@<digest>` (empty without push) |
| `mirror-ref` | `<ecr-prefix>/<name>@<digest>` (empty without a mirror or push) |

### Caller

The calling job must grant `packages: write` (GHCR push with the run's
`GITHUB_TOKEN`) and `id-token: write` (cosign keyless):

```yaml
name: image
on:
  push:
    branches: [develop]
  pull_request:

jobs:
  image:
    uses: agrippa-io/github-actions/.github/workflows/image-build.yml@v1
    permissions:
      contents: read
      packages: write
      id-token: write
    with:
      push: ${{ github.event_name == 'push' }}
      workload: gateway
      buildkit-secret-name: npm_token
    secrets:
      buildkit-secret-value: ${{ secrets.NPM_TOKEN }}
      dispatch-token: ${{ secrets.GITOPS_DISPATCH_TOKEN }}
```

### Verifying a signature

The certificate identity is this reusable workflow, not the caller, so one
policy covers every repo (what the DC-3 3.6 admission policy checks):

```bash
cosign verify ghcr.io/agrippa-io/<image>@sha256:… \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/agrippa-io/github-actions/\.github/workflows/image-build\.yml@'
```

The caller's repo is in the certificate too (`--certificate-github-workflow-repository`)
if a policy needs to restrict by source repo.

### Self-test

`image-build-selftest.yml` runs the workflow on every change to it against
[`../test/fixtures/image-build`](../test/fixtures/image-build), pushes
`ghcr.io/agrippa-io/github-actions-image-build-selftest`, then checks from a
separate job that the index has amd64 + arm64, the tag resolves to the output
digest, and the signature verifies.
