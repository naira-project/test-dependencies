# =============================================================================
# OpenBao platform component
# =============================================================================
#
# OpenBao, installed with Helm, and its ClusterSecretStore. Stays in this
# repository until it moves to test-infrastructure (Terraform).
#
# External Secrets Operator is a prerequisite provided by the cluster:
# test-infrastructure installs it with Argo CD (ESO_CHART_VERSION below is
# that version, used only in the hint for clusters without it).
#
# Command surfaces:
#   platform-openbao-*   — Platform Engineering operations (init, seed, reset)
#   testbed-openbao-*    — Developer read-only inspection
#
# Typical first-time setup:
#   make platform-openbao-up
#   make platform-openbao-init       # once per cluster lifetime
#   # seal unseal-keys-sealed.yaml, commit, kubectl apply -k
#   make platform-openbao-seed
#
# Subsequent re-seeds (e.g. after adding new API keys to .env.testbed):
#   make platform-openbao-seed

OPENBAO_NS       := naira-platform-openbao
OPENBAO_DIR      := infrastructure/platform/openbao
OPENBAO_STORE_DIR := $(OPENBAO_DIR)/eso/clustersecretstore
OPENBAO_SVC      := openbao-active
OPENBAO_API_PORT := 8200
OPENBAO_CHART_VERSION := 0.28.2
ESO_NS           := external-secrets
ESO_CHART_VERSION := 2.11.0
# Pass FORCE=true to overwrite existing secrets: make platform-openbao-seed FORCE=true
FORCE            ?= false

.PHONY: platform-openbao-up platform-openbao-init platform-openbao-seed \
        platform-openbao-reset platform-openbao-upgrade \
        testbed-openbao-status testbed-openbao-port-forward \
        testbed-openbao-seed-status testbed-openbao-inspect \
        _openbao-require-eso _openbao-helm-install _openbao-apply-clustersecretstore _openbao-wait-ready \
        _openbao-reconcile-clustersecretstore _openbao-run-init \
        _openbao-run-seed _openbao-require-token

## [PLATFORM] Deploy OpenBao with Helm and its ClusterSecretStore. Needs ESO.
platform-openbao-up: _openbao-require-eso
	@echo ">>> Applying namespace and RBAC..."
	kubectl apply -k $(OPENBAO_DIR)/
	$(MAKE) _openbao-helm-install
	$(MAKE) _openbao-apply-clustersecretstore
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
	@echo ">>> Uninstalling the OpenBao release..."
	helm uninstall openbao -n $(OPENBAO_NS) --ignore-not-found
	@echo ">>> Deleting namespace $(OPENBAO_NS)..."
	kubectl delete namespace $(OPENBAO_NS) --ignore-not-found --wait=true
	@echo ">>> Redeploying..."
	$(MAKE) platform-openbao-up

## [PLATFORM] Apply a chart version or values change. Edit OPENBAO_CHART_VERSION
## or values.yaml first, then run this.
platform-openbao-upgrade: _openbao-helm-install
	@echo "Upgrade applied. The OpenBao StatefulSet uses OnDelete; to roll the pod:"
	@echo "  kubectl delete pod openbao-0 -n $(OPENBAO_NS)"

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
	@echo "=== Helm release ==="
	helm status openbao -n $(OPENBAO_NS) 2>/dev/null | head -5 || echo "(openbao release not found)"

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

_openbao-require-eso:
	@kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1 || { \
	  echo "ERROR: External Secrets Operator is not installed (CRD clustersecretstores.external-secrets.io missing)."; \
	  echo "  The cluster provides it; test-infrastructure installs chart $(ESO_CHART_VERSION). On a local cluster:"; \
	  echo "    helm install external-secrets external-secrets --repo https://charts.external-secrets.io \\"; \
	  echo "      --version $(ESO_CHART_VERSION) -n $(ESO_NS) --create-namespace --wait"; \
	  exit 1; \
	}

# Without --wait: the OpenBao pod is not Ready until initialized and unsealed.
_openbao-helm-install:
	@echo ">>> Installing openbao $(OPENBAO_CHART_VERSION)..."
	helm upgrade --install openbao openbao \
	  --repo https://openbao.github.io/openbao-helm --version '$(OPENBAO_CHART_VERSION)' \
	  -n $(OPENBAO_NS) -f $(OPENBAO_DIR)/values.yaml

# Retried: the webhook Deployment can be Available before its Service has
# endpoints, and the apply is rejected until it does.
_openbao-apply-clustersecretstore:
	@echo ">>> Applying ClusterSecretStore..."
	@for i in $$(seq 1 30); do \
	  kubectl apply -k $(OPENBAO_STORE_DIR) && exit 0; \
	  echo "    ... ESO webhook not ready yet, retrying"; sleep 5; \
	done; exit 1

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
