# CLAUDE.md — test-dependencies

Guidance for AI coding agents working in this repository.

## What this repo is

Test-environment infrastructure for Naira, an open-source internal development
platform that connects existing AI tooling in Kubernetes (it does not implement
inference or gateways itself). This repo provides:

- **Platform components** (`infrastructure/platform/`) — always-on, owned by
  Platform Engineering. Currently OpenBao + External Secrets Operator (ESO).
- **Testbeds** (`infrastructure/testbed/`) — per-developer, disposable instances
  of third-party tools that Naira plugins integrate with. Currently LiteLLM and MLflow.

Everything is Kubernetes manifests reconciled by Flux, driven by `make`. There is no
application code, no unit test suite and no CI workflow in `.github/`.

## Layout

```
Makefile                              # all operational entry points
.env.testbed.example                  # template for OpenBao seed inputs (.env.testbed is gitignored)
infrastructure/
  platform/openbao/                   # OpenBao HelmRelease, init/seed Jobs, RBAC, Flux Kustomizations
    eso/                              # ESO HelmRelease + ClusterSecretStore "openbao-platform"
  testbed/litellm/                    # OCIRepository, HelmRelease, ExternalSecret, smoke-test Job
  testbed/mlflow/                     # GitRepository (mlflow/mlflow), HelmRelease, seed Job
charts/naira-dependencies/            # untracked; Chart.lock + vendored .tgz only, no Chart.yaml
```

Each component directory has a `README.md` with the full runbook. Read it before
changing that component.

## Commands

Read-only, safe to run:

```bash
make testbed-mlflow-status
make testbed-litellm-status
make testbed-openbao-status
make testbed-litellm-secret-scan        # fails if a LiteLLM api_key is not an os.environ/ ref
make testbed-openbao-seed-status        # needs testbed-openbao-port-forward in another pane
make testbed-openbao-inspect            # same
kubectl kustomize infrastructure/testbed/<name>   # render manifests without applying
```

Mutate cluster state — confirm with the user and show `kubectl config current-context` first:

```bash
make testbed-{mlflow,litellm}-{up,down,reset,seed,smoke}
make platform-openbao-{up,init,seed,reset,upgrade}
```

`platform-openbao-reset` deletes the `naira-platform-openbao` and `external-secrets`
namespaces and destroys all stored secrets. `platform-openbao-init` is once per
cluster lifetime.

Variables:

| Variable      | Default                                         | Used by                         |
| ------------- | ----------------------------------------------- | ------------------------------- |
| `FLUX_SOURCE` | `component-testbed`                             | all `*-up` targets              |
| `NS`          | `naira-testbed-mlflow` / `naira-testbed-litellm` | testbed targets only            |
| `FORCE`       | `false`                                         | `platform-openbao-seed`         |

## Conventions and constraints

- **Namespace templating.** Testbed manifests use `${MLFLOW_NS}` / `${LITELLM_NS}`.
  They are resolved twice: by `envsubst` in the Makefile (for the Flux Kustomization,
  seed and smoke Jobs) and by Flux `postBuild.substitute` (for everything under the
  Kustomization path). New namespaced testbed resources must use the variable, not
  a hardcoded namespace.
- **envsubst is restricted to named variables** in testbed targets
  (`envsubst '$$FLUX_SOURCE $$LITELLM_NS'`). This keeps shell variables inside Job
  scripts (e.g. `${PROXY_MASTER_KEY}`) intact. Preserve the explicit list when
  editing those targets.
- **`flux-kustomization*.yaml` is not listed in `kustomization.yaml`** — including it
  creates a self-referencing loop. It is applied only by `make`.
- **Flux source prerequisite.** `*-up` targets require a `GitRepository` named
  `$FLUX_SOURCE` in `flux-system`; they do not create it.
- **Adding a testbed:** mirror an existing one — `namespace.yaml`, source,
  `helm-release.yaml`, `kustomization.yaml`, `flux-kustomization.yaml`, an on-demand
  Job for seed/smoke, a `README.md`, and a Makefile block with
  `up/down/reset/status/port-forward` targets plus `.PHONY` entries.
- **Pin versions.** Helm charts and upstream Git sources are pinned (LiteLLM chart
  `1.82.3`, MLflow chart from a pinned commit). Do not switch to floating tags.
- **Seed and smoke Jobs must be idempotent** — `make` deletes and re-creates them.

## Secrets

- Never commit secret values. `.env.testbed` is gitignored; only
  `.env.testbed.example` is tracked with empty values.
- Workloads get secrets only via `ExternalSecret` → `ClusterSecretStore`
  `openbao-platform`. LiteLLM config references keys as `os.environ/<VAR>`.
- Paths under `secret/testbed/` are a public contract with plugin authors — do not
  rename them. Adding a path means updating `seed-job.yaml`, `.env.testbed.example`
  and the path table in `infrastructure/platform/openbao/README.md`.
- `unseal-keys-sealed.yaml` must only ever contain an encrypted (SealedSecrets or
  SOPS) Secret.
- The OpenBao setup has deliberate test-only compromises (no TLS, single Raft node,
  root token in seed job, unseal key in a Secret). Do not "fix" them silently and do
  not copy them into anything production-facing; see section 8 of the OpenBao README.

## Ownership and review

`CODEOWNERS` requires platform team approval for `infrastructure/platform/**`.
Keep testbed changes and platform changes in separate PRs where possible.

## Testing changes

There is no automated test target. Verify with what exists:

1. `kubectl kustomize infrastructure/<component>` renders without error.
2. `make testbed-litellm-secret-scan` passes for LiteLLM changes.
3. On a cluster (after confirming context): `make testbed-<name>-up`, then
   `make testbed-<name>-status`; the `up` target runs the seed or smoke Job and
   fails if it does not complete.

The PR template's `go test` and Docker Compose checkboxes do not apply to this repo.

## Unresolved template content

`README.md`, `REUSE.toml` and the root `AGENTS.md` still hold SAP repository-template
placeholders. Do not treat them as project documentation.
