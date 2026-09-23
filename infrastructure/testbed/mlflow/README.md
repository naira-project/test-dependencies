# MLflow Testbed

Reproducible MLflow Tracking Server and Model Registry for developing and testing the Naira MLflow Sync Plugin.

Deployed as a Kubernetes workload in namespace `naira-testbed-mlflow` by default, synced by Argo CD.

## Purpose

The Naira MLflow Sync Controller translates MLflow Registered Models and Model Versions into Naira's generic entity format. This testbed provides a real MLflow instance pre-seeded with sample data so the plugin team can develop and test locally without manually installing or configuring MLflow.

## Prerequisites

- `kubectl` configured against a Kubernetes cluster (Minikube is supported)
- `make`
- `envsubst`
- Argo CD installed in namespace `argocd`
- This repo reachable by Argo CD at `REPO_URL` (default: the public GitHub URL)
  - Argo CD syncs from `REVISION` (default `main`); push your branch and pass
    `REVISION=<branch>` to test unmerged changes

## Quick Start

```bash
# Sync MLflow via Argo CD and seed sample data (~2 min)
make testbed-mlflow-up

# Optional: use a developer-owned namespace
NS=my-mlflow make testbed-mlflow-up

# Access the UI locally
make testbed-mlflow-port-forward
# → open http://localhost:5000 in your browser
```

Tear down:

```bash
make testbed-mlflow-down
```

## Commands

| Command                            | Description                                    |
| ---------------------------------- | ---------------------------------------------- |
| `make testbed-mlflow-up`           | Deploy MLflow and run the seed job             |
| `make testbed-mlflow-down`         | Delete the namespace and all resources         |
| `make testbed-mlflow-reset`        | Tear down and recreate from scratch            |
| `make testbed-mlflow-status`       | Show pods, services, PVCs, and Argo CD state   |
| `make testbed-mlflow-port-forward` | Forward `localhost:5000` to the MLflow service |
| `make testbed-mlflow-seed`         | Re-run the seed job (idempotent)               |

## Seeded Data

The seed job (`seed-job.yaml`) populates the Model Registry with:

| Model                 | Versions | Aliases                     |
| --------------------- | -------- | --------------------------- |
| `text-classifier-v1`  | 2        | staging, production         |
| `sentiment-analyzer`  | 3        | (none), staging, production |
| `summarization-model` | 2        | staging, production         |

Each version includes tags (`framework`, `task`, `validated_by`) and logged metrics (`accuracy`/`f1_score`/`latency_ms` or `rouge1`/`rouge2`/`latency_ms`).

One experiment (`testbed-experiments`) is created with 2 baseline runs.

The seed script is **idempotent**: re-running `make testbed-mlflow-seed` does not create duplicates.

MLflow 3 removes lifecycle stages (Staging/Production). The seed uses model version aliases instead (`staging`, `production`).

## Accessing MLflow from Within the Cluster

Other pods in the cluster can reach the MLflow API at:

```
http://mlflow.naira-testbed-mlflow.svc.cluster.local:5000
```

Example — list registered models from another pod:

```bash
curl http://mlflow.naira-testbed-mlflow.svc.cluster.local:5000/api/2.0/mlflow/registered-models/list
```

Set the tracking URI in your plugin code:

```python
import mlflow
mlflow.set_tracking_uri("http://mlflow.naira-testbed-mlflow.svc.cluster.local:5000")
```

## Argo CD Sync

`make testbed-mlflow-up` applies `application.yaml` as an Argo CD Application named after the namespace. It renders the official MLflow chart (`oci://ghcr.io/mlflow/charts/mlflow`) with `values.yaml` from `REPO_URL` at `REVISION`. Pushed changes to `values.yaml` sync automatically.

```bash
make testbed-mlflow-status
kubectl get application naira-testbed-mlflow -n argocd
```

## Architecture

```
naira-testbed-mlflow namespace
├── Deployment/mlflow          — MLflow Tracking Server (official mlflow/mlflow chart)
│     image: ghcr.io/mlflow/mlflow:v3.12.0-full
│     backend: SQLite at /mlflow/mlflow.db
│     artifacts: /mlflow/artifacts (proxied through server)
│     workers: 1; BLAS/math libraries capped to one thread per process
│     resources: 500m–2 CPU, 512Mi–2Gi RAM
├── Service/mlflow             — ClusterIP :5000
├── PersistentVolumeClaim/mlflow — 1Gi (data survives pod restarts)
└── Job/mlflow-seed            — one-shot Python seed job (idempotent)
```

No Ingress is configured. Use `make testbed-mlflow-port-forward` for local browser access.

## Manifest Layout

```
infrastructure/testbed/mlflow/
├── application.yaml          # Argo CD Application (chart oci://ghcr.io/mlflow/charts/mlflow)
├── values.yaml               # MLflow chart values
└── seed-job.yaml             # ConfigMap (seed.py) + Job
```
