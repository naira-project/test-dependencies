# PoC environment

ArgoCD Applications used for the RFC-009 proof of concept on a local kind
cluster. Not an environment anyone else can sync as-is.

- `naira.yaml` installs the released naira chart from
  `oci://ghcr.io/naira-project/charts/naira` with its images from
  `ghcr.io/naira-project` (public, amd64 and arm64).
- `test-dependencies.yaml` installs this repository's chart from a local OCI
  registry reachable in-cluster as `naira-poc-registry-tls:5000` (charts, TLS)
  and `naira-poc-registry:5000` (the `mcp-mock` image). It moves to ghcr once
  `chart-publish.yml` and `mcp-mock-image.yml` have published both.

The scripts that created that registry and its certificates lived under
`deploy/poc/` on the naira branch `feat/rfc-009-deployment-consolidation`,
which no longer exists. Recreating the registry means pushing the chart
(`helm push`) and the `mcp-mock` image to it and loading its CA into
`argocd-tls-certs-cm` by hand.

All credentials in these files (`admin`/`admin`, `sk-local-litellm`,
`naira-local-dev-secret`, `change-me`) are local development placeholders.
