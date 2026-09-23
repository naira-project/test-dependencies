# Naira Test Dependencies

## About this project

This repository provides reproducible, Kubernetes-based test dependencies for developing and testing [Naira](https://github.com/naira-project) plugins. Naira does not implement inferencing, AI gateways or model registries itself; it connects to existing tools in Kubernetes. The components here give plugin developers real instances of those tools, reconciled by Flux, instead of mocks.

The repository has two kinds of components:

| Component | Kind | Path | Default namespace | Purpose |
| --- | --- | --- | --- | --- |
| [OpenBao](infrastructure/platform/openbao/README.md) | Platform | `infrastructure/platform/openbao/` | `naira-platform-openbao` | Central secret store, consumed via External Secrets Operator (`ClusterSecretStore` `openbao-platform`) |
| [MLflow](infrastructure/testbed/mlflow/README.md) | Testbed | `infrastructure/testbed/mlflow/` | `naira-testbed-mlflow` | Tracking server and Model Registry, pre-seeded with sample models |
| [LiteLLM](infrastructure/testbed/litellm/README.md) | Testbed | `infrastructure/testbed/litellm/` | `naira-testbed-litellm` | LiteLLM Proxy with Mistral routes, plus a chat and embeddings smoke test |

- **Platform** components are always on and operated by Platform Engineering (`make platform-*`).
- **Testbeds** are spun up per developer on demand (`make testbed-*`).

See the README in each component directory for architecture, commands and troubleshooting.

## Requirements and Setup

### Prerequisites

- A Kubernetes cluster and `kubectl` configured against it (Minikube works)
- `helm`, `make`, `envsubst`
- Flux (source-controller and helm-controller)
- A Flux `GitRepository` in `flux-system` that points to this repository. The default name is `component-testbed`; override it with `FLUX_SOURCE=<name>`:

  ```bash
  flux create source git component-testbed --url=https://github.com/naira-project/test-dependencies --branch=main --namespace=flux-system
  ```

- For LiteLLM: the OpenBao platform component, seeded with `LITELLM_MISTRAL_API_KEY`

### Quick start

```bash
# 1. Platform: secret store and External Secrets Operator (once per cluster)
make platform-openbao-up
make platform-openbao-init   # once per cluster lifetime
make platform-openbao-seed   # reads secrets from .env.testbed

# 2. Testbeds (each on its own)
make testbed-mlflow-up
make testbed-litellm-up

# Optional: deploy a testbed into your own namespace
NS=my-mlflow make testbed-mlflow-up
```

Each testbed provides `-up`, `-down`, `-reset`, `-status` and `-port-forward` targets:

| Service | Port-forward target | Local URL |
| --- | --- | --- |
| MLflow | `make testbed-mlflow-port-forward` | http://127.0.0.1:5000 |
| LiteLLM | `make testbed-litellm-port-forward` | http://127.0.0.1:4000 |
| OpenBao | `make testbed-openbao-port-forward` | http://127.0.0.1:8200/ui |

### Makefile variables

| Variable | Default | Description |
| --- | --- | --- |
| `FLUX_SOURCE` | `component-testbed` | Name of the Flux `GitRepository` for this repository |
| `NS` | component default | Target namespace for a testbed instance |
| `FORCE` | `false` | Overwrite existing secrets in `make platform-openbao-seed` |

> **Note:** These components are for test environments only. They are not hardened for production (for example, OpenBao runs without TLS).

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/naira-project/test-dependencies/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/naira-project/test-dependencies/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

Please refer to our [Code of Conduct](https://github.com/naira-project/.github/blob/main/CODE_OF_CONDUCT.md) for information on the expected conduct for contributing to Naira.

<p align="center"><img alt="Bundesministerium für Wirtschaft und Energie (BMWE)-EU funding logo" src="https://apeirora.eu/assets/img/BMWK-EU.png" width="400"/></p>
