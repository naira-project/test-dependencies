# OpenBao — Naira Platform Secret Store

OpenBao is the always-on, centralized secret store for the Naira test environment.
It is platform infrastructure, not a developer testbed — operated by the Platform
Engineering team and consumed by every plugin via External Secrets Operator (ESO).

> **OpenBao** is the open-source, community-driven fork of HashiCorp Vault,
> governed under the Linux Foundation. It is the natural fit for Naira (a Linux
> Foundation Europe / NeoNephos project): both share open governance and Apache 2.0 licensing.

---

## Table of Contents

1. [Purpose and framing](#1-purpose-and-framing)
2. [Architecture](#2-architecture)
3. [Developer commands](#3-developer-commands-testbed-openbao-)
4. [Platform Engineer commands](#4-platform-engineer-commands-platform-openbao-)
5. [Operator runbook](#5-operator-runbook)
6. [ESO consumption examples](#6-eso-consumption-examples)
7. [Secret path reference](#7-secret-path-reference)
8. [Known test-environment compromises](#8-known-test-environment-compromises)

---

## 1. Purpose and framing

### What OpenBao is (in this repo)

- **Always running** alongside the cluster, kgateway, Platform Mesh, and Argo CD
- **Owned by Platform Engineering** — not provisioned or operated by application developers
- **A hard prerequisite** of every testbed and every plugin that reads secrets
- **Bootstrapped once** per test environment; upgraded as a platform operation

### What OpenBao is not

- A testbed like LiteLLM or MLflow (those are spun up per-developer)
- Anything production — this deployment is explicitly test-environment-only

### Who does what

| Action                                       | Owner                                       |
| -------------------------------------------- | ------------------------------------------- |
| Deploy / init / reset / upgrade              | Platform Engineering                        |
| Seed secrets from `.env.testbed`             | Platform Engineering                        |
| Add a new reserved path                      | Platform Engineering (PR to this directory) |
| Check seal status, list seeded paths         | Any developer                               |
| Declare `ExternalSecret` and consume secrets | Any plugin developer                        |
| Write to `secret/scratch/<username>/*`       | Any developer (self-service)                |

---

## 2. Architecture

### OpenBao server

- **Helm chart**: `openbao/openbao` v0.28.x from `https://openbao.github.io/openbao-helm`
- **Mode**: HA mode with integrated Raft storage, single replica
- **Storage**: PersistentVolumeClaim at `/openbao/data` (Raft WAL — survives pod restarts)
- **Listener**: HTTP on `:8200` / cluster on `:8201` — TLS disabled (test environment only)
- **UI**: enabled, accessible via port-forward only (no Ingress)
- **Lease TTL**: 24h default, 168h max (encourages testing rotation behavior)

### Auto-unseal sidecar

The `unsealer` sidecar container runs alongside the OpenBao container. On every pod
start it polls the OpenBao API and calls `bao operator unseal` as soon as the server
is ready. The unseal key is read from the `openbao-unseal-keys` Secret.

If the Secret does not exist yet (i.e., before `platform-openbao-init` has run),
the sidecar sleeps indefinitely and the pod starts but stays sealed. Once the init
job creates the Secret, the next pod restart picks it up automatically.

### External Secrets Operator

ESO is deployed in the `external-secrets` namespace by the `external-secrets`
Argo CD Application, next to the `openbao` Application (both in `application.yaml`).
Chart values live in `values.yaml` and `eso/values.yaml`; Argo CD syncs pushed changes.

A single `ClusterSecretStore` named `openbao-platform` is available cluster-wide.
Any namespace can reference it from `ExternalSecret` resources to project OpenBao
KV v2 secrets into native Kubernetes Secrets.
It is synced from `infrastructure/platform/openbao/eso/clustersecretstore.yaml`
in sync wave 1, after the ESO chart (CRDs + webhook) is healthy.

ESO authenticates to OpenBao via the Kubernetes auth method: it presents its own
ServiceAccount token; OpenBao verifies it against the cluster's TokenReview API.

### Secret path layout

```
secret/
  testbed/          # platform-managed; values from .env.testbed
    litellm/
      mistral       → api_key
      openai        → api_key
      anthropic     → api_key
      azure-openai  → api_key, api_base, api_version
    mlflow/
      s3            → access_key, secret_key, endpoint_url
    openmetadata/
      admin         → username, password
    argocd/
      admin         → username, password
    grafana/
      admin         → username, password
    langfuse/
      api           → public_key, secret_key, host
    kserve/
      model-registry → url, token
    opendatahub/
      admin         → username, password
  demo/             # deterministic placeholders, always written by seed job
    hello           → message, platform
    connection      → host, port, tls
  scratch/          # developer-owned; never touched by platform seed
    <username>/
      ...
```

---

## 3. Developer commands (`testbed-openbao-*`)

These commands are safe for any developer to run at any time.

```bash
# Show pod status, seal status, ClusterSecretStore, and Argo CD state
make testbed-openbao-status

# Port-forward OpenBao UI and API to http://127.0.0.1:8200
# UI: http://127.0.0.1:8200/ui
make testbed-openbao-port-forward

# List which secret paths are currently seeded (requires port-forward in another terminal)
make testbed-openbao-seed-status

# Show enabled secret engines and auth methods (requires port-forward)
make testbed-openbao-inspect
```

---

## 4. Platform Engineer commands (`platform-openbao-*`)

These commands modify cluster state. They are documented for Platform Engineers and
should not be run by developers without understanding the implications.

```bash
# Deploy OpenBao + ESO platform component
make platform-openbao-up

# Initialize OpenBao (one-time per cluster lifetime)
# Creates the openbao-unseal-keys Secret. See Operator Runbook below.
make platform-openbao-init

# Seed engines, auth, policies, and secrets from .env.testbed
# cp .env.testbed.example .env.testbed  →  fill in values  →  run:
make platform-openbao-seed

# Force-overwrite existing secret values (use with care)
make platform-openbao-seed FORCE=true

# Full teardown + redeploy (destroys all secrets — use only in dev clusters)
make platform-openbao-reset

# Update chart version (edit application.yaml first, then re-apply)
make platform-openbao-up
```

---

## 5. Operator Runbook

### First-time environment setup

1. **Deploy the platform component**:

   ```bash
   make platform-openbao-up
   ```

   OpenBao starts but remains sealed (no unseal key yet).

2. **Initialize OpenBao**:

   ```bash
   make platform-openbao-init
   ```

   This runs the init job, which calls `bao operator init` and writes the unseal
   key and root token to the `openbao-unseal-keys` Secret. The job prints
   detailed post-init instructions in its log.

3. **Encrypt and commit the unseal key** (mandatory — do not skip):

   **With SealedSecrets:**

   ```bash
   kubeseal --fetch-cert --controller-namespace kube-system \
     > /tmp/sealed-secrets-cert.pem

   kubectl get secret openbao-unseal-keys \
     -n naira-platform-openbao -o yaml \
     | kubeseal --cert /tmp/sealed-secrets-cert.pem \
         --scope namespace-wide -o yaml \
     > infrastructure/platform/openbao/unseal-keys-sealed.yaml
   ```

   Argo CD applies plain manifests only, so use SealedSecrets (SOPS would need an
   Argo CD decryption plugin such as KSOPS).

   Then add `unseal-keys-sealed.yaml` to `kustomization.yaml` resources, commit, and push:

   ```bash
   git add infrastructure/platform/openbao/unseal-keys-sealed.yaml
   git add infrastructure/platform/openbao/kustomization.yaml
   git commit -m "feat: add encrypted unseal keys for <environment-name>"
   ```

4. **Restart the OpenBao pod** so the unsealer sidecar picks up the key:

   ```bash
   kubectl rollout restart statefulset/openbao -n naira-platform-openbao
   kubectl rollout status statefulset/openbao -n naira-platform-openbao
   ```

5. **Seed OpenBao**:
   ```bash
   cp .env.testbed.example .env.testbed
   # Fill in complete credential bundles; blank required fields skip those paths
   make platform-openbao-seed
   ```

### Re-seeding (adding new values)

```bash
# Edit .env.testbed to add new values, then:
make platform-openbao-seed
# Existing paths are preserved. Blank or incomplete entries are skipped.
# To overwrite existing values:
make platform-openbao-seed FORCE=true
```

### Verifying auto-unseal works

```bash
# Delete the pod and watch it recover
kubectl delete pod openbao-0 -n naira-platform-openbao
kubectl get pods -n naira-platform-openbao -w
# Expect: openbao-0 transitions Running → Running (2/2) within ~30s
make testbed-openbao-status  # seal status should be false
```

### Recovering from a wiped cluster

The encrypted `unseal-keys-sealed.yaml` only unlocks an existing OpenBao data
store. It does not initialize a fresh, empty `/openbao/data` volume.

If the cluster control plane was wiped but the OpenBao persistent volume was
preserved:

1. Re-apply the platform manifests: `make platform-openbao-up`
2. Argo CD syncs the SealedSecret; the controller recreates `openbao-unseal-keys`
3. Pod starts → unsealer sidecar reads key → unseals automatically
4. Re-run seed: `make platform-openbao-seed`

If the OpenBao persistent volume was deleted, the stored key no longer belongs
to the new empty OpenBao data store. Re-initialize from scratch:
`make platform-openbao-reset`, then `make platform-openbao-init`, then encrypt
and commit the new `openbao-unseal-keys` Secret.

---

## 6. ESO Consumption Examples

All examples use the `ClusterSecretStore` named `openbao-platform`. The store is
available cluster-wide — no additional configuration needed in consuming namespaces.

### Basic pattern

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-secret
  namespace: my-namespace
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-platform
    kind: ClusterSecretStore
  target:
    name: my-secret # resulting Kubernetes Secret name
    creationPolicy: Owner
  data:
    - secretKey: api_key # key in the resulting k8s Secret
      remoteRef:
        key: testbed/litellm/mistral # path in OpenBao (without "secret/")
        property: api_key # field within the KV entry
```

### Per-plugin examples

**LiteLLM — Mistral API key**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: litellm-mistral-secret }
  data:
    - secretKey: MISTRAL_API_KEY
      remoteRef: { key: testbed/litellm/mistral, property: api_key }
```

**LiteLLM — OpenAI API key**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: litellm-openai-secret }
  data:
    - secretKey: OPENAI_API_KEY
      remoteRef: { key: testbed/litellm/openai, property: api_key }
```

**LiteLLM — Azure OpenAI**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: litellm-azure-secret }
  data:
    - secretKey: AZURE_API_KEY
      remoteRef: { key: testbed/litellm/azure-openai, property: api_key }
    - secretKey: AZURE_API_BASE
      remoteRef: { key: testbed/litellm/azure-openai, property: api_base }
    - secretKey: AZURE_API_VERSION
      remoteRef: { key: testbed/litellm/azure-openai, property: api_version }
```

**Langfuse API credentials**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: langfuse-credentials }
  data:
    - secretKey: LANGFUSE_PUBLIC_KEY
      remoteRef: { key: testbed/langfuse/api, property: public_key }
    - secretKey: LANGFUSE_SECRET_KEY
      remoteRef: { key: testbed/langfuse/api, property: secret_key }
    - secretKey: LANGFUSE_HOST
      remoteRef: { key: testbed/langfuse/api, property: host }
```

**Grafana admin credentials**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: grafana-admin }
  data:
    - secretKey: GF_SECURITY_ADMIN_USER
      remoteRef: { key: testbed/grafana/admin, property: username }
    - secretKey: GF_SECURITY_ADMIN_PASSWORD
      remoteRef: { key: testbed/grafana/admin, property: password }
```

**ArgoCD admin credentials**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: argocd-initial-admin-secret }
  data:
    - secretKey: password
      remoteRef: { key: testbed/argocd/admin, property: password }
```

**OpenMetadata admin credentials**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: openmetadata-admin }
  data:
    - secretKey: username
      remoteRef: { key: testbed/openmetadata/admin, property: username }
    - secretKey: password
      remoteRef: { key: testbed/openmetadata/admin, property: password }
```

**KServe model registry**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: kserve-model-registry }
  data:
    - secretKey: MODEL_REGISTRY_URL
      remoteRef: { key: testbed/kserve/model-registry, property: url }
    - secretKey: MODEL_REGISTRY_TOKEN
      remoteRef: { key: testbed/kserve/model-registry, property: token }
```

**MLflow S3 artifact store credentials**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: mlflow-s3-credentials }
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef: { key: testbed/mlflow/s3, property: access_key }
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef: { key: testbed/mlflow/s3, property: secret_key }
    - secretKey: MLFLOW_S3_ENDPOINT_URL
      remoteRef: { key: testbed/mlflow/s3, property: endpoint_url }
```

**Demo hello secret (smoke-test)**

```yaml
spec:
  secretStoreRef: { name: openbao-platform, kind: ClusterSecretStore }
  target: { name: openbao-demo }
  data:
    - secretKey: message
      remoteRef: { key: demo/hello, property: message }
```

---

## 7. Secret path reference

| OpenBao path                           | Fields                                     | Source env var(s)           |
| -------------------------------------- | ------------------------------------------ | --------------------------- |
| `secret/testbed/litellm/mistral`       | `api_key`                                  | `LITELLM_MISTRAL_API_KEY`   |
| `secret/testbed/litellm/openai`        | `api_key`                                  | `LITELLM_OPENAI_API_KEY`    |
| `secret/testbed/litellm/anthropic`     | `api_key`                                  | `LITELLM_ANTHROPIC_API_KEY` |
| `secret/testbed/litellm/azure-openai`  | `api_key`, `api_base`, `api_version`       | `LITELLM_AZURE_OPENAI_*`    |
| `secret/testbed/mlflow/s3`             | `access_key`, `secret_key`, `endpoint_url` | `MLFLOW_S3_*`               |
| `secret/testbed/openmetadata/admin`    | `username`, `password`                     | `OPENMETADATA_ADMIN_*`      |
| `secret/testbed/argocd/admin`          | `username`, `password`                     | `ARGOCD_ADMIN_*`            |
| `secret/testbed/grafana/admin`         | `username`, `password`                     | `GRAFANA_ADMIN_*`           |
| `secret/testbed/langfuse/api`          | `public_key`, `secret_key`, `host`         | `LANGFUSE_*`                |
| `secret/testbed/kserve/model-registry` | `url`, `token`                             | `KSERVE_MODEL_REGISTRY_*`   |
| `secret/testbed/opendatahub/admin`     | `username`, `password`                     | `OPENDATAHUB_ADMIN_*`       |
| `secret/demo/hello`                    | `message`, `platform`                      | — (always written)          |
| `secret/demo/connection`               | `host`, `port`, `tls`                      | — (always written)          |
| `secret/scratch/<username>/*`          | any                                        | developer self-service      |

Path stability guarantee: once a path under `secret/testbed/` is published, it is
not renamed without a deprecation notice. Paths are part of the public contract
with plugin authors.

---

## 8. Known test-environment compromises

This deployment makes deliberate trade-offs that are acceptable for a test
environment but must NOT be replicated in production.

| Compromise                                                                          | Production requirement                                                                          |
| ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Unseal key stored in a Kubernetes Secret (base64, not encrypted at rest by default) | Real auto-unseal via cloud KMS (AWS KMS, GCP Cloud KMS, Azure Key Vault) or Transit auto-unseal |
| HTTP listener — no TLS                                                              | TLS with valid certificates; mTLS for inter-node Raft                                           |
| Single Raft node — no high availability                                             | 3+ node Raft cluster for quorum                                                                 |
| Audit logging disabled (keeps stdout noise low)                                     | Audit log to file or syslog, retained for compliance                                            |
| Root token used by seed job                                                         | Short-lived, narrowly-scoped tokens via AppRole or OIDC                                         |
| No backup/restore workflow                                                          | Regular Raft snapshots with offsite storage                                                     |
