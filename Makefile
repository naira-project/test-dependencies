# Git repo + revision Argo CD syncs this repo's manifests from.
# Override to test a pushed branch or fork:
#   REVISION=my-branch make testbed-litellm-up
REPO_URL ?= https://github.com/naira-project/test-dependencies.git
REVISION ?= main

# Override the target namespace for developer-owned testbed instances:
#   NS=my-litellm make testbed-litellm-up
#   NS=my-mlflow make testbed-mlflow-up
NS ?=

# =============================================================================
# MLflow testbed
# =============================================================================

MLFLOW_DEFAULT_NS := naira-testbed-mlflow
MLFLOW_NS        := $(if $(NS),$(NS),$(MLFLOW_DEFAULT_NS))
MLFLOW_DIR       := infrastructure/testbed/mlflow
MLFLOW_SVC       := mlflow
MLFLOW_PORT      := 5000

LITELLM_DEFAULT_NS := naira-testbed-litellm
LITELLM_NS       := $(if $(NS),$(NS),$(LITELLM_DEFAULT_NS))
LITELLM_DIR      := infrastructure/testbed/litellm
LITELLM_SVC      := litellm
LITELLM_PORT     := 4000

.PHONY: testbed-mlflow-up testbed-mlflow-down testbed-mlflow-reset \
        testbed-mlflow-status testbed-mlflow-port-forward testbed-mlflow-seed \
        _mlflow-run-seed \
        testbed-litellm-up testbed-litellm-down testbed-litellm-reset \
        testbed-litellm-status testbed-litellm-port-forward testbed-litellm-smoke \
        testbed-litellm-secret-scan \
        _litellm-run-smoke

## Provision MLflow testbed: deploy + seed sample data.
testbed-mlflow-up:
	@echo ">>> Applying Argo CD Application..."
	MLFLOW_NS=$(MLFLOW_NS) REPO_URL=$(REPO_URL) REVISION=$(REVISION) envsubst '$$MLFLOW_NS $$REPO_URL $$REVISION' < $(MLFLOW_DIR)/application.yaml | kubectl apply -f -
	@echo ">>> Waiting for Argo CD sync..."
	kubectl wait application/$(MLFLOW_NS) -n argocd --for=jsonpath='{.status.sync.status}'=Synced --timeout=180s
	kubectl wait application/$(MLFLOW_NS) -n argocd --for=jsonpath='{.status.health.status}'=Healthy --timeout=180s
	@echo ">>> Running seed job..."
	$(MAKE) _mlflow-run-seed
	@echo ""
	@echo "MLflow testbed is up."
	@echo "  UI:  make testbed-mlflow-port-forward  →  http://127.0.0.1:$(MLFLOW_PORT)"
	@echo "  API: http://$(MLFLOW_SVC).$(MLFLOW_NS).svc.cluster.local:$(MLFLOW_PORT)"

## Tear down MLflow testbed: delete namespace and all resources.
testbed-mlflow-down:
	@echo ">>> Deleting Argo CD Application (cascades to its resources)..."
	kubectl delete application $(MLFLOW_NS) -n argocd --ignore-not-found --wait=true
	@echo ">>> Deleting namespace $(MLFLOW_NS)..."
	kubectl delete namespace $(MLFLOW_NS) --ignore-not-found --wait=true
	@echo "MLflow testbed removed."

## Full teardown + recreate from scratch.
testbed-mlflow-reset: testbed-mlflow-down testbed-mlflow-up

## Show pod status, service, and Argo CD sync state.
testbed-mlflow-status:
	@echo "=== Pods ==="
	kubectl get pods -n $(MLFLOW_NS) 2>/dev/null || echo "(namespace not found)"
	@echo ""
	@echo "=== Services ==="
	kubectl get svc -n $(MLFLOW_NS) 2>/dev/null || true
	@echo ""
	@echo "=== PVCs ==="
	kubectl get pvc -n $(MLFLOW_NS) 2>/dev/null || true
	@echo ""
	@echo "=== Argo CD Application ==="
	kubectl get application $(MLFLOW_NS) -n argocd 2>/dev/null || echo "(Application not found — run 'NS=$(MLFLOW_NS) make testbed-mlflow-up')"

## Open kubectl port-forward to http://127.0.0.1:5000.
testbed-mlflow-port-forward:
	@echo ">>> Forwarding http://127.0.0.1:$(MLFLOW_PORT) → svc/$(MLFLOW_SVC):$(MLFLOW_PORT)"
	@echo "    Press Ctrl+C to stop."
	kubectl port-forward svc/$(MLFLOW_SVC) $(MLFLOW_PORT):$(MLFLOW_PORT) -n $(MLFLOW_NS)

## Re-run the seed job without redeploying MLflow (idempotent).
testbed-mlflow-seed:
	$(MAKE) _mlflow-run-seed

# --- internal targets ---

_mlflow-run-seed:
	@echo ">>> Deleting previous seed job (if any)..."
	kubectl delete job mlflow-seed -n $(MLFLOW_NS) --ignore-not-found
	@echo ">>> Applying seed job..."
	kubectl apply -n $(MLFLOW_NS) -f $(MLFLOW_DIR)/seed-job.yaml
	@echo ">>> Waiting for seed job to complete..."
	kubectl wait --for=condition=complete job/mlflow-seed -n $(MLFLOW_NS) --timeout=120s
	@echo ">>> Seed job finished."

# =============================================================================
# OpenBao platform component
# =============================================================================
#
# Command surfaces:
#   platform-openbao-*   — Platform Engineering operations (init, seed, reset)
#   testbed-openbao-*    — Developer read-only inspection
#
# Typical first-time setup:
#   make platform-openbao-up
#   make platform-openbao-init       # once per cluster lifetime
#   # encrypt unseal-keys-sealed.yaml, commit, kubectl apply -k
#   make platform-openbao-seed
#
# Chart upgrades: edit application.yaml, then re-run make platform-openbao-up.
#
# Subsequent re-seeds (e.g. after adding new API keys to .env.testbed):
#   make platform-openbao-seed

OPENBAO_NS       := naira-platform-openbao
OPENBAO_DIR      := infrastructure/platform/openbao
OPENBAO_SVC      := openbao-active
OPENBAO_API_PORT := 8200
# Pass FORCE=true to overwrite existing secrets: make platform-openbao-seed FORCE=true
FORCE            ?= false

.PHONY: platform-openbao-up platform-openbao-init platform-openbao-seed \
        platform-openbao-reset \
        testbed-openbao-status testbed-openbao-port-forward \
        testbed-openbao-seed-status testbed-openbao-inspect \
        _openbao-wait-ready \
        _openbao-reconcile-clustersecretstore _openbao-run-init \
        _openbao-run-seed _openbao-require-token

## [PLATFORM] Deploy (or upgrade) the OpenBao platform component and ESO via Argo CD.
platform-openbao-up:
	@echo ">>> Applying Argo CD Applications (openbao, external-secrets)..."
	REPO_URL=$(REPO_URL) REVISION=$(REVISION) envsubst '$$REPO_URL $$REVISION' < $(OPENBAO_DIR)/application.yaml | kubectl apply -f -
	@echo ">>> Waiting for Argo CD sync (ClusterSecretStore waits for ESO)..."
	kubectl wait application/openbao application/external-secrets -n argocd \
	  --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s
	@echo ""
	@echo "OpenBao platform component applied."
	@echo "  OpenBao will start but remain sealed until you run:"
	@echo "    make platform-openbao-init"

## [PLATFORM] Initialize OpenBao (one-time per cluster). Creates openbao-unseal-keys Secret.
platform-openbao-init: _openbao-run-init

## [PLATFORM] Seed OpenBao with engines, auth, policies, and secrets from .env.testbed.
platform-openbao-seed:
	@if [ ! -f .env.testbed ]; then \
	  echo "ERROR: .env.testbed not found."; \
	  echo "  cp .env.testbed.example .env.testbed  # then fill in values"; \
	  exit 1; \
	fi
	$(MAKE) _openbao-run-seed

## [PLATFORM] Full teardown + redeploy from scratch. Destroys all secrets in OpenBao.
platform-openbao-reset:
	@echo ">>> Deleting Argo CD Applications (cascades to their resources)..."
	kubectl delete application openbao external-secrets -n argocd --ignore-not-found --wait=true
	@echo ">>> Deleting namespace $(OPENBAO_NS)..."
	kubectl delete namespace $(OPENBAO_NS) --ignore-not-found --wait=true
	kubectl delete namespace external-secrets --ignore-not-found --wait=true
	@echo ">>> Redeploying..."
	$(MAKE) platform-openbao-up

## [DEVELOPER] Show OpenBao platform component status.
testbed-openbao-status:
	@echo "=== Pods ==="
	kubectl get pods -n $(OPENBAO_NS) 2>/dev/null || echo "(namespace not found)"
	@echo ""
	@echo "=== Services ==="
	kubectl get svc -n $(OPENBAO_NS) 2>/dev/null || true
	@echo ""
	@echo "=== PVCs ==="
	kubectl get pvc -n $(OPENBAO_NS) 2>/dev/null || true
	@echo ""
	@echo "=== Seal Status ==="
	kubectl exec -n $(OPENBAO_NS) statefulset/openbao -c openbao -- \
	  bao status 2>/dev/null || echo "(pod not ready)"
	@echo ""
	@echo "=== ClusterSecretStore ==="
	kubectl get clustersecretstore openbao-platform 2>/dev/null || \
	  echo "(ClusterSecretStore not found — ESO may still be deploying)"
	@echo ""
	@echo "=== Argo CD Applications ==="
	kubectl get application openbao external-secrets -n argocd 2>/dev/null || \
	  echo "(Applications not found — run make platform-openbao-up)"

## [DEVELOPER] Port-forward OpenBao API and UI to http://127.0.0.1:8200.
testbed-openbao-port-forward:
	@echo ">>> Forwarding http://127.0.0.1:$(OPENBAO_API_PORT) → svc/$(OPENBAO_SVC):$(OPENBAO_API_PORT)"
	@echo "    UI: http://127.0.0.1:$(OPENBAO_API_PORT)/ui"
	@echo "    Press Ctrl+C to stop."
	kubectl port-forward svc/$(OPENBAO_SVC) $(OPENBAO_API_PORT):$(OPENBAO_API_PORT) -n $(OPENBAO_NS)

## [DEVELOPER] Show which secret paths are currently seeded in OpenBao.
testbed-openbao-seed-status: _openbao-require-token
	@echo "=== Seeded Paths ==="
	@echo ""
	@echo "--- secret/demo/ ---"
	BAO_ADDR=http://127.0.0.1:$(OPENBAO_API_PORT) \
	BAO_TOKEN=$$(kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) \
	  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d) \
	bao kv list secret/demo/ 2>/dev/null || echo "(empty or not seeded)"
	@echo ""
	@echo "--- secret/testbed/ ---"
	BAO_ADDR=http://127.0.0.1:$(OPENBAO_API_PORT) \
	BAO_TOKEN=$$(kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) \
	  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d) \
	bao kv list secret/testbed/ 2>/dev/null || echo "(empty or not seeded)"
	@echo ""
	@echo "Tip: run 'make testbed-openbao-port-forward' in a separate terminal first."

## [DEVELOPER] Show enabled secret engines and auth methods.
testbed-openbao-inspect: _openbao-require-token
	@echo "=== Enabled Secret Engines ==="
	BAO_ADDR=http://127.0.0.1:$(OPENBAO_API_PORT) \
	BAO_TOKEN=$$(kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) \
	  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d) \
	bao secrets list 2>/dev/null || echo "(OpenBao not reachable — run port-forward first)"
	@echo ""
	@echo "=== Enabled Auth Methods ==="
	BAO_ADDR=http://127.0.0.1:$(OPENBAO_API_PORT) \
	BAO_TOKEN=$$(kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) \
	  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d) \
	bao auth list 2>/dev/null || true

# --- internal targets ---

_openbao-require-token:
	@kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) >/dev/null 2>&1 || \
	  { echo "ERROR: openbao-unseal-keys Secret not found — run platform-openbao-init first."; exit 1; }

_openbao-wait-ready:
	@echo ">>> Waiting for OpenBao pod to be ready (may take 60–90s on first deploy)..."
	kubectl wait pod/openbao-0 -n $(OPENBAO_NS) --for=condition=Ready --timeout=180s

_openbao-reconcile-clustersecretstore:
	@echo ">>> Reconciling ClusterSecretStore after OpenBao auth changes..."
	@if kubectl get clustersecretstore openbao-platform >/dev/null 2>&1; then \
	  kubectl annotate clustersecretstore openbao-platform \
	    reconcile.external-secrets.io/force=$$(date +%s) --overwrite; \
	  kubectl wait --for=condition=Ready clustersecretstore/openbao-platform --timeout=60s; \
	else \
	  echo "    (ClusterSecretStore openbao-platform not found — skipping)"; \
	fi

_openbao-run-init:
	@echo ">>> Deleting previous init job (if any)..."
	kubectl delete job openbao-init -n $(OPENBAO_NS) --ignore-not-found
	@echo ">>> Applying init job..."
	kubectl apply -f $(OPENBAO_DIR)/init-job.yaml
	@echo ">>> Waiting for init job to complete..."
	kubectl wait --for=condition=complete job/openbao-init -n $(OPENBAO_NS) --timeout=120s
	@echo ">>> Init job finished."
	@echo ""
	@echo ">>> Restarting OpenBao pod so unsealer sidecar picks up the unseal key..."
	@echo "    (StatefulSet uses OnDelete — pod must be deleted manually)"
	kubectl delete pod openbao-0 -n $(OPENBAO_NS)
	@echo ">>> Waiting for OpenBao pod to be ready and unsealed..."
	kubectl wait pod/openbao-0 -n $(OPENBAO_NS) --for=condition=Ready --timeout=120s
	@echo ""
	@echo "OpenBao initialized and unsealed."
	@echo "  Next steps printed above by the init job."

_openbao-run-seed:
	@echo ">>> Creating openbao-seed-input Secret from .env.testbed..."
	kubectl create secret generic openbao-seed-input \
	  -n $(OPENBAO_NS) \
	  --from-env-file=.env.testbed \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo ">>> Deleting previous seed job (if any)..."
	kubectl delete job openbao-seed -n $(OPENBAO_NS) --ignore-not-found
	kubectl delete configmap openbao-seed-script -n $(OPENBAO_NS) --ignore-not-found
	@echo ">>> Applying seed job..."
	@if [ "$(FORCE)" = "true" ]; then \
	  sed 's/value: "false"/value: "true"/' $(OPENBAO_DIR)/seed-job.yaml \
	    | kubectl apply -f -; \
	else \
	  kubectl apply -f $(OPENBAO_DIR)/seed-job.yaml; \
	fi
	@echo ">>> Waiting for seed job to complete..."
	kubectl wait --for=condition=complete job/openbao-seed -n $(OPENBAO_NS) --timeout=180s
	@echo ">>> Cleaning up openbao-seed-input Secret..."
	kubectl delete secret openbao-seed-input -n $(OPENBAO_NS) --ignore-not-found
	$(MAKE) _openbao-reconcile-clustersecretstore
	@echo ">>> Seed job finished."

## Provision LiteLLM testbed: deploy via Argo CD + run smoke test.
testbed-litellm-up:
	@echo ">>> Applying Argo CD Application..."
	LITELLM_NS=$(LITELLM_NS) REPO_URL=$(REPO_URL) REVISION=$(REVISION) envsubst '$$LITELLM_NS $$REPO_URL $$REVISION' < $(LITELLM_DIR)/application.yaml | kubectl apply -f -
	@echo ">>> Waiting for Argo CD sync..."
	kubectl wait application/$(LITELLM_NS) -n argocd --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s
	kubectl wait application/$(LITELLM_NS) -n argocd --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s
	@echo ">>> Running LiteLLM smoke test..."
	$(MAKE) _litellm-run-smoke
	@echo ""
	@echo "LiteLLM testbed is up."
	@echo "  API: make testbed-litellm-port-forward  ->  http://127.0.0.1:$(LITELLM_PORT)"
	@echo "  In cluster: http://$(LITELLM_SVC).$(LITELLM_NS).svc.cluster.local:$(LITELLM_PORT)"

## Tear down LiteLLM testbed: delete namespace and all resources.
testbed-litellm-down:
	@echo ">>> Deleting Argo CD Application (cascades to its resources)..."
	kubectl delete application $(LITELLM_NS) -n argocd --ignore-not-found --wait=true
	@echo ">>> Deleting namespace $(LITELLM_NS)..."
	kubectl delete namespace $(LITELLM_NS) --ignore-not-found --wait=true
	@echo "LiteLLM testbed removed."

## Full teardown + recreate from scratch.
testbed-litellm-reset: testbed-litellm-down testbed-litellm-up

## Show pod status, service, ExternalSecret, and Argo CD sync state.
testbed-litellm-status:
	@echo "=== Pods ==="
	kubectl get pods -n $(LITELLM_NS) 2>/dev/null || echo "(namespace not found)"
	@echo ""
	@echo "=== Services ==="
	kubectl get svc -n $(LITELLM_NS) 2>/dev/null || true
	@echo ""
	@echo "=== ExternalSecret ==="
	kubectl get externalsecret litellm-mistral-api-key -n $(LITELLM_NS) 2>/dev/null || echo "(ExternalSecret not found)"
	@echo ""
	@echo "=== Argo CD Application ==="
	kubectl get application $(LITELLM_NS) -n argocd 2>/dev/null || echo "(Application not found — run 'NS=$(LITELLM_NS) make testbed-litellm-up')"

## Open kubectl port-forward to http://127.0.0.1:4000.
testbed-litellm-port-forward:
	@echo ">>> Forwarding http://127.0.0.1:$(LITELLM_PORT) -> svc/$(LITELLM_SVC):$(LITELLM_PORT)"
	@echo "    Press Ctrl+C to stop."
	kubectl port-forward svc/$(LITELLM_SVC) $(LITELLM_PORT):$(LITELLM_PORT) -n $(LITELLM_NS)

## Run chat + embeddings smoke test through LiteLLM.
testbed-litellm-smoke:
	$(MAKE) _litellm-run-smoke

## Check LiteLLM manifests for plaintext API key values.
testbed-litellm-secret-scan:
	@echo ">>> Checking $(LITELLM_DIR) for plaintext LiteLLM API keys..."
	@awk '/api_key:/ && $$0 !~ /os.environ\// { print FILENAME ":" FNR ":" $$0; found=1 } END { exit found }' $(LITELLM_DIR)/*.yaml
	@echo "No plaintext LiteLLM api_key values found."

_litellm-run-smoke:
	@echo ">>> Deleting previous smoke test job (if any)..."
	kubectl delete job litellm-smoke-test -n $(LITELLM_NS) --ignore-not-found
	@echo ">>> Applying smoke test job..."
	kubectl apply -n $(LITELLM_NS) -f $(LITELLM_DIR)/smoke-test-job.yaml
	@echo ">>> Waiting for smoke test to complete..."
	kubectl wait --for=condition=complete job/litellm-smoke-test -n $(LITELLM_NS) --timeout=180s
	@echo ">>> Smoke test finished."
