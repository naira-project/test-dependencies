# PoC environment

ArgoCD Applications used for the RFC-009 proof of concept on a local kind
cluster. Not an environment anyone else can sync as-is.

Assumes a local OCI registry reachable in-cluster as
`naira-poc-registry-tls:5000` (charts, TLS) and `naira-poc-registry:5000`
(images). The registry and its certs are created by PoC scripts under
`deploy/poc/` in the `naira` repository, branch
`feat/rfc-009-deployment-consolidation` — not present in this repo.

All credentials in these files (`admin`/`admin`, `sk-local-litellm`,
`naira-local-dev-secret`, `change-me`) are local development placeholders.
