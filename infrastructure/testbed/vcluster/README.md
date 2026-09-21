# vCluster GitOps spike

Spike for [product#66](https://github.com/naira-project/product/issues/66). Not for merge.

ArgoCD reconciles `instances/` into a cluster running vCluster Platform.
`argocd-application.yaml` is applied by hand; it is outside the synced path.

| File | What |
|---|---|
| `instances/project.yaml` | Platform project. Wave 0. |
| `instances/dev-ephemeral.yaml` | vCluster pinned to the tainted `ephemeral` NodePool; stopped nightly. |
| `instances/staging.yaml` | vCluster pinned to `general-purpose`; must survive the nightly stop. |
