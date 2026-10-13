# test-dependencies

## About this project

The third-party tier Naira talks to but does not ship (RFC-009 §1): Keycloak,
LiteLLM with its PostgreSQL, MLflow, OpenMetadata, llama.cpp, vLLM,
kube-prometheus-stack and `mcp-mock`, packaged as one Helm chart. It is
versioned independently of Naira, because these components move on upstream
release cycles, not on Naira's.

The [naira chart](https://github.com/naira-project/naira/tree/main/deploy/charts/naira)
installs Naira itself and only needs these components' addresses. Its
defaults expect this chart in namespace `naira-deps`.

## Repository layout

| Path | Contents |
|---|---|
| `charts/test-dependencies/` | The chart. `values.yaml` holds operator defaults (Secrets supplied externally), `values-dev.yaml` a single-node kind or colima setup, `tests/render-test.sh` the render assertions. |
| `images/mcp-mock/` | Source of `mcp-mock`, a test double for the catalog's `mcp-servers` plugin. Dev only. |
| `argocd/environments/poc/` | ArgoCD Applications from the RFC-009 proof of concept. See its README. |
| `.github/workflows/` | `chart.yml` (lint, render tests, kubeconform, kind install), `chart-publish.yml` (chart to ghcr on tag `v<version>`), `mcp-mock-image.yml` (image to ghcr). |

## Components

One Helm tag per component. `values.yaml` turns on what an operator who runs
none of this needs; `values-dev.yaml` adds what a local Naira needs.

| Tag | Installs | `values.yaml` | `values-dev.yaml` |
|---|---|---|---|
| `keycloak` | Keycloak with realm `naira` (`files/naira-realm.json`) | on | on |
| `litellm` | LiteLLM and its PostgreSQL | on | on |
| `mlflow` | MLflow, SQLite on PVC `mlflow-data` | on | on |
| `mcpMock` | `mcp-mock` | off | on |
| `llamacpp` | llama.cpp, one Deployment per model | off | on |
| `vllm` | vLLM (exclusive with `llamacpp`) | off | off |
| `openmetadata` | OpenMetadata with MySQL and OpenSearch | off | off |
| `monitoring` | kube-prometheus-stack and the ServiceMonitors | off | off |

## Requirements and Setup

### Local cluster with Naira

Needs `helm` 4, `kubectl`, `yq` v4, and a single-node kind or colima cluster
with about 4 CPUs and 8 GiB.

1. Fetch the chart's dependencies. Helm 4 does not fetch from unregistered
   HTTP repositories:

   ```sh
   helm repo add community-charts https://community-charts.github.io/helm-charts
   helm repo add open-metadata https://helm.open-metadata.org
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm dependency build charts/test-dependencies
   ```

2. Load the `mcp-mock` image into the cluster, until ghcr serves it publicly:

   ```sh
   TAG=$(sed -n 's/^appVersion: "\(.*\)"/\1/p' charts/test-dependencies/Chart.yaml)
   IMG=ghcr.io/naira-project/test-dependencies/mcp-mock:$TAG
   # colima with the containerd runtime
   colima nerdctl -- --namespace k8s.io build -t "$IMG" images/mcp-mock
   # kind
   docker build -t "$IMG" images/mcp-mock && kind load docker-image "$IMG"
   ```

3. Install this chart into `naira-deps`:

   ```sh
   helm upgrade --install test-dependencies charts/test-dependencies \
     -n naira-deps --create-namespace \
     -f charts/test-dependencies/values-dev.yaml --wait --timeout 10m
   ```

4. Install the released naira chart into `idp-system`, the only namespace
   its UI works in for now. The values are the PoC Application's: development
   Secrets only, everything else is the chart's defaults.

   ```sh
   yq '.spec.source.helm.valuesObject' argocd/environments/poc/naira.yaml \
     | helm upgrade --install naira oci://ghcr.io/naira-project/charts/naira \
         --version "$(yq '.spec.source.targetRevision' argocd/environments/poc/naira.yaml)" \
         -n idp-system --create-namespace -f - --wait --timeout 10m
   ```

5. Reach it from the browser. The issuer is `http://localhost:8080`, so
   Keycloak must be forwarded on that port:

   ```sh
   kubectl -n naira-deps port-forward svc/keycloak 8080:8080 &
   kubectl -n idp-system port-forward svc/portal 3000:3000 &
   kubectl -n idp-system port-forward svc/ui 3001:80 &
   ```

   Portal at <http://localhost:3000>, user `testuser`, password `testpass`.

Every credential in `values-dev.yaml`, `files/naira-realm.json` and
`argocd/environments/poc/` is a local development placeholder.

### Other clusters

Keep `values.yaml`'s default of operator-supplied Secrets (the
`secrets.*.create: false` keys document each name and key) and set
`keycloak.hostname` to the address browsers use. Released charts:

```sh
helm install test-dependencies oci://ghcr.io/naira-project/charts/test-dependencies \
  --version <version> -n naira-deps --create-namespace -f my-values.yaml
```

### Tests

```sh
charts/test-dependencies/tests/render-test.sh   # after helm dependency build; needs yq v4
```

### Publishing

- Chart: push tag `v<version>` with `<version>` equal to `version` in
  `charts/test-dependencies/Chart.yaml`.
- `mcp-mock`: built for amd64 and arm64 on pushes to `main` that change
  `images/mcp-mock/` or `Chart.yaml`, and published under the chart's
  `appVersion` when that tag does not exist yet. A published `appVersion` is
  never overwritten: an image change needs an `appVersion` bump. The ghcr package must be made public once, by an
  organization owner, before clusters can pull it without credentials.

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/naira-project/test-dependencies/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/naira-project/test-dependencies/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

Please refer to our [Code of Conduct](https://github.com/naira-project/.github/blob/main/CODE_OF_CONDUCT.md) for information on the expected conduct for contributing to Platform Mesh.

<p align="center"><img alt="Bundesministerium für Wirtschaft und Energie (BMWE)-EU funding logo" src="https://apeirora.eu/assets/img/BMWK-EU.png" width="400"/></p>
