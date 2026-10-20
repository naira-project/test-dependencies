#!/usr/bin/env bash
# Render assertions for the test-dependencies chart.
# Needs helm and mikefarah yq v4. Run `helm dependency build` on the chart first.
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

render() { helm template t "$CHART" --namespace deps "$@"; }

check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

must_fail() {
  local name=$1 want=$2 out; shift 2
  if out=$(render "$@" 2>&1); then echo "FAIL $name: rendered without error"; fail=1
  elif [[ $out == *"$want"* ]]; then echo "ok   $name"
  else echo "FAIL $name: wrong error: $out"; fail=1; fi
}

check "chart name" "test-dependencies" "$(helm show chart "$CHART" | yq '.name')"
check "openmetadata version" "2.0.1" \
  "$(helm show chart "$CHART" | yq '.dependencies[] | select(.name == "openmetadata") | .version')"
must_fail "llamacpp and vllm are exclusive" "mutually exclusive" \
  --set tags.llamacpp=true --set tags.vllm=true

LITELLM='select(.kind == "Deployment" and .metadata.name == "litellm") | .spec.template.spec.containers[0]'

check "no generated masterkey Secret by default" "" \
  "$(render | yq 'select(.kind == "Secret" and .metadata.name == "litellm-masterkey") | .metadata.name')"
check "litellm reads masterkey from litellm-masterkey" "litellm-masterkey" \
  "$(render | yq "$LITELLM | .env[] | select(.name == \"PROXY_MASTER_KEY\") | .valueFrom.secretKeyRef.name")"
check "litellm serves /metrics by default" "prometheus" \
  "$(render | yq 'select(.kind == "ConfigMap" and .metadata.name == "litellm-config") | .data["config.yaml"]' | yq '.litellm_settings.callbacks[0]')"
check "litellm loads provider keys" "litellm-provider-keys" \
  "$(render | yq "$LITELLM | .envFrom[].secretRef.name")"
check "masterkey Secret when create=true" "sk-test" \
  "$(render --set secrets.litellmMasterkey.create=true --set secrets.litellmMasterkey.value=sk-test \
     | yq 'select(.kind == "Secret" and .metadata.name == "litellm-masterkey") | .stringData.masterkey')"
check "provider keys Secret when create=true" "k1" \
  "$(render --set secrets.litellmProviderKeys.create=true --set secrets.litellmProviderKeys.data.MISTRAL_API_KEY=k1 \
     | yq 'select(.kind == "Secret" and .metadata.name == "litellm-provider-keys") | .stringData.MISTRAL_API_KEY')"
must_fail "masterkey create needs a value" "secrets.litellmMasterkey.value is required" \
  --set secrets.litellmMasterkey.create=true

# LiteLLM's database is on Naira's PostgreSQL
check "no PostgreSQL objects" "0" \
  "$(render | yq ea '[select(.metadata.name | test("postgres"))] | length')"
check "litellm connects to Naira's PostgreSQL" "postgres.idp-system.svc.cluster.local:5432 litellm" \
  "$(render | yq "$LITELLM | (.env[] | select(.name == \"DATABASE_HOST\") | .value) + \" \" + (.env[] | select(.name == \"DATABASE_NAME\") | .value)")"
check "litellm reads its database credentials from litellm-db" "litellm-db litellm-db" \
  "$(render | yq ea "$LITELLM | [.env[] | select(.name == \"DATABASE_USERNAME\" or .name == \"DATABASE_PASSWORD\") | .valueFrom.secretKeyRef.name] | join(\" \")")"
check "no generated litellm-db Secret by default" "" \
  "$(render | yq 'select(.kind == "Secret" and .metadata.name == "litellm-db") | .metadata.name')"
must_fail "litellm-db create needs a password" "secrets.litellmDatabase.password is required" \
  --set secrets.litellmDatabase.create=true
must_fail "litellm must not deploy its own PostgreSQL" "litellm.db.deployStandalone must be false" \
  --set litellm.db.deployStandalone=true
# Only mlflow's flask key may differ between two default renders
a=$(mktemp); b=$(mktemp); render > "$a"; render > "$b"
changed=""
for n in $(yq ea '[select(.kind == "Secret") | .metadata.name] | .[]' "$a"); do
  q="select(.kind == \"Secret\" and .metadata.name == \"$n\") | (.data // .stringData)"
  [ "$(yq "$q" "$a" | cksum)" = "$(yq "$q" "$b" | cksum)" ] || changed="$changed$n "
done
check "default renders differ only in the mlflow flask key" "mlflow-flask-server-secret-key " "$changed"
rm -f "$a" "$b"

DEV=(-f "$CHART/values-dev.yaml")
check "dev: mcp-mock on" "mcp-mock" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Deployment" and .metadata.name == "mcp-mock") | .metadata.name')"
check "dev: mcp-mock image is the published one, tagged with appVersion" \
  "ghcr.io/naira-project/test-dependencies/mcp-mock:$(helm show chart "$CHART" | yq '.appVersion')" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Deployment" and .metadata.name == "mcp-mock") | .spec.template.spec.containers[0].image')"
check "mcp-mock: no imagePullSecrets by default" "null" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Deployment" and .metadata.name == "mcp-mock") | .spec.template.spec.imagePullSecrets')"
check "mcp-mock: imagePullSecrets from values" "ghcr-pull" \
  "$(render "${DEV[@]}" --set 'mcpMock.imagePullSecrets[0].name=ghcr-pull' | yq 'select(.kind == "Deployment" and .metadata.name == "mcp-mock") | .spec.template.spec.imagePullSecrets[0].name')"
check "dev: llama.cpp models rendered" "llama-dummy-model,llama-qwen25-05b" \
  "$(render "${DEV[@]}" | yq ea '[select(.kind == "Deployment" and .metadata.name == "llama-*") | .metadata.name] | sort | join(",")')"
check "dev: vllm off" "" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Deployment" and .metadata.name == "vllm") | .metadata.name')"
check "dev: masterkey Secret created" "sk-local-litellm" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Secret" and .metadata.name == "litellm-masterkey") | .stringData.masterkey')"
check "dev: provider keys Secret created" "litellm-provider-keys" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Secret" and .metadata.name == "litellm-provider-keys") | .metadata.name')"
n=$(render "${DEV[@]}" | grep -c 'naira-poc-registry' || true)   # grep exits 1 on no match
check "dev: no image points at the ci/poc-values.yaml registry" "0" "${n:-0}"
a=$(mktemp); b=$(mktemp); render "${DEV[@]}" > "$a"; render "${DEV[@]}" > "$b"
check "dev: two renders are identical" "yes" "$(cmp -s "$a" "$b" && echo yes || echo no)"
rm -f "$a" "$b"
a=$(mktemp); b=$(mktemp); render "${DEV[@]}" --set tags.openmetadata=true > "$a"; render "${DEV[@]}" --set tags.openmetadata=true > "$b"
check "dev+openmetadata: two renders are identical" "yes" "$(cmp -s "$a" "$b" && echo yes || echo no)"
rm -f "$a" "$b"
a=$(mktemp); b=$(mktemp); render "${DEV[@]}" --set tags.monitoring=true > "$a"; render "${DEV[@]}" --set tags.monitoring=true > "$b"
check "dev+monitoring: two renders are identical" "yes" "$(cmp -s "$a" "$b" && echo yes || echo no)"
rm -f "$a" "$b"
check "ServiceMonitor for litellm is absent when litellm is off" "" \
  "$(render --set tags.monitoring=true --set tags.litellm=false | yq ea 'select(.kind == "ServiceMonitor" and .metadata.name == "litellm") | .metadata.name')"
check "dev: litellm-db Secret matches the naira chart's values-dev.yaml" "litellm litellm-local-password" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Secret" and .metadata.name == "litellm-db") | .stringData.username + " " + .stringData.password')"

# keycloak admin Secret
must_fail "keycloak admin create needs a username" "keycloak.admin.username is required" \
  --set keycloak.admin.create=true --set keycloak.admin.password=x
must_fail "keycloak admin create needs a password" "keycloak.admin.password is required" \
  --set keycloak.admin.create=true --set keycloak.admin.username=x
must_fail "keycloak admin: existing and create" "keycloak.admin: set existingSecret or create, not both" \
  --set keycloak.admin.create=true --set keycloak.admin.existingSecret=x --set keycloak.admin.username=x --set keycloak.admin.password=x

# keycloak realm import: bundled by default, replaceable per environment
KCVOL='select(.kind == "Deployment" and .metadata.name == "keycloak") | .spec.template.spec.volumes[] | select(.name == "realm-import") | .configMap.name'
check "keycloak imports the bundled realm by default" "keycloak-realm-import" "$(render | yq "$KCVOL")"
check "keycloak imports an existing realm ConfigMap" "my-realm" \
  "$(render --set keycloak.realmImport.existingConfigMap=my-realm | yq "$KCVOL")"
check "no bundled realm ConfigMap with existingConfigMap" "" \
  "$(render --set keycloak.realmImport.existingConfigMap=my-realm \
     | yq 'select(.kind == "ConfigMap" and .metadata.name == "keycloak-realm-import") | .metadata.name')"

check "mcp-mock off by default" "" \
  "$(render | yq 'select(.kind == "Deployment" and .metadata.name == "mcp-mock") | .metadata.name')"
check "ServiceMonitor carries the release label" "t" \
  "$(render --set tags.monitoring=true | yq 'select(.kind == "ServiceMonitor" and .metadata.name == "litellm") | .metadata.labels.release')"

# inference backends
LLAMA='select(.kind == "Deployment" and .metadata.name == "llama-qwen25-05b") | .spec.template.spec'
check "llamacpp: init container downloads the model" "download-model" \
  "$(render --set tags.llamacpp=true | yq "$LLAMA | .initContainers[0].name")"
check "llamacpp: server exposes metrics" "true" \
  "$(render --set tags.llamacpp=true | yq "$LLAMA | .containers[0].args | contains([\"--metrics\"])")"
check "llamacpp: fsGroup so the unprivileged downloader can write the PVC" "$(yq '.llamacpp.fsGroup' "$CHART/values.yaml")" \
  "$(render --set tags.llamacpp=true | yq "$LLAMA | .securityContext.fsGroup")"
check "llamacpp: one model cache PVC per model" "llama-dummy-model-model-cache,llama-qwen25-05b-model-cache" \
  "$(render --set tags.llamacpp=true | yq ea '[select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("^llama"))) | .metadata.name] | sort | join(",")')"
check "llamacpp: each Deployment mounts its own PVC" "llama-dummy-model-model-cache,llama-qwen25-05b-model-cache" \
  "$(render --set tags.llamacpp=true | yq ea '[select(.kind == "Deployment" and (.metadata.name | test("^llama"))) | .spec.template.spec.volumes[0].persistentVolumeClaim.claimName] | sort | join(",")')"
check "llamacpp: maxSurge 0, so a ReadWriteOnce volume is released before the new pod starts" "RollingUpdate/0/1" \
  "$(render --set tags.llamacpp=true | yq ea '[select(.kind == "Deployment" and (.metadata.name | test("^llama"))) | .spec.strategy | .type + "/" + (.rollingUpdate.maxSurge | tostring) + "/" + (.rollingUpdate.maxUnavailable | tostring)] | unique | join(",")')"
check "llamacpp: Services are labelled as inference" "llama-dummy-model,llama-qwen25-05b" \
  "$(render --set tags.llamacpp=true | yq ea '[select(.kind == "Service" and .metadata.labels["app.kubernetes.io/component"] == "inference") | .metadata.name] | sort | join(",")')"
check "llamacpp: models come from values" "llama-only" \
  "$(render --set tags.llamacpp=true --set-json 'llamacpp.models=[{"name":"llama-only","modelFile":"m.gguf","downloadUrl":"https://example.invalid/m.gguf","resources":{}}]' | yq ea 'select(.kind == "Deployment" and .metadata.name == "llama-*") | .metadata.name')"
check "llamacpp: off by default" "" \
  "$(render | yq ea 'select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("model-cache$"))) | .metadata.name')"
VLLM='select(.kind == "Deployment" and .metadata.name == "vllm") | .spec.template.spec.containers[0]'
check "vllm: container port is vLLM's own 8000" "8000" \
  "$(render --set tags.vllm=true | yq "$VLLM | .ports[0].containerPort")"
check "vllm: Service targets the named port" "8000" \
  "$(render --set tags.vllm=true | yq 'select(.kind == "Service" and .metadata.name == "vllm") | .spec.ports[0].port')"
check "vllm: serves the configured model name" "opt-125m" \
  "$(render --set tags.vllm=true | yq "$VLLM | .args[2]")"
check "vllm: --enforce-eager skips the torch.compile warm-up" "true" \
  "$(render --set tags.vllm=true | yq "$VLLM | .args | contains([\"--enforce-eager\"])")"
check "vllm: enforceEager is a switch" "false" \
  "$(render --set tags.vllm=true --set vllm.enforceEager=false | yq "$VLLM | .args | contains([\"--enforce-eager\"])")"
check "vllm: maxSurge 0, so a rollout never runs two vLLM pods" "0" \
  "$(render --set tags.vllm=true | yq 'select(.kind == "Deployment" and .metadata.name == "vllm") | .spec.strategy.rollingUpdate.maxSurge')"
check "vllm: startup probe gates liveness for a 10-minute start" "600" \
  "$(render --set tags.vllm=true | yq "$VLLM | .startupProbe.periodSeconds * .startupProbe.failureThreshold")"
check "vllm: Hugging Face cache survives container restarts" "/root/.cache/huggingface" \
  "$(render --set tags.vllm=true | yq "$VLLM | .volumeMounts[] | select(.name == \"hf-cache\") | .mountPath")"
check "vllm: mounts the chat template" "vllm-chat-template" \
  "$(render --set tags.vllm=true | yq 'select(.kind == "ConfigMap" and .metadata.name == "vllm-chat-template") | .metadata.name')"
check "inference ServiceMonitor follows monitoring + a backend" "inference" \
  "$(render --set tags.monitoring=true --set tags.llamacpp=true | yq ea 'select(.kind == "ServiceMonitor" and .metadata.name == "inference") | .metadata.name')"
check "inference ServiceMonitor also for vllm" "inference" \
  "$(render --set tags.monitoring=true --set tags.vllm=true | yq ea 'select(.kind == "ServiceMonitor" and .metadata.name == "inference") | .metadata.name')"
check "no inference ServiceMonitor without a backend" "" \
  "$(render --set tags.monitoring=true | yq ea 'select(.kind == "ServiceMonitor" and .metadata.name == "inference") | .metadata.name')"
check "no inference ServiceMonitor without monitoring" "" \
  "$(render --set tags.llamacpp=true | yq ea 'select(.kind == "ServiceMonitor") | .metadata.name')"

# openmetadata: server and dependencies on one tag, no Airflow
OM=(--set tags.openmetadata=true)
check "openmetadata off by default" "" \
  "$(render | yq 'select(.kind == "Deployment" and .metadata.name == "openmetadata") | .metadata.name')"
check "openmetadata on: server and opensearch rendered, no mysql" "openmetadata,opensearch" \
  "$(render "${OM[@]}" | yq ea '[select((.kind == "Deployment" or .kind == "StatefulSet") and (.metadata.name == "openmetadata" or (.metadata.name | test("mysql")) or .metadata.name == "opensearch")) | .metadata.name] | sort | join(",")')"
check "openmetadata on: no bitnami image" "0" \
  "$(render "${OM[@]}" | yq ea '[.. | select(has("image")) | .image | select(test("bitnami"))] | length')"
check "openmetadata connects to its database on Naira's PostgreSQL" "postgres.idp-system.svc.cluster.local 5432 openmetadata postgresql" \
  "$(render "${OM[@]}" | yq 'select(.kind == "Secret" and .data.DB_HOST != null) | .data | (.DB_HOST | @base64d) + " " + (.DB_PORT | @base64d) + " " + (.OM_DATABASE | @base64d) + " " + (.DB_SCHEME | @base64d)')"
check "openmetadata on: no airflow" "0" \
  "$(render "${OM[@]}" | yq ea '[select(.kind == "Deployment" or .kind == "StatefulSet") | .metadata.name | select(test("airflow"))] | length')"
check "openmetadata on: pipeline service client disabled" "false" \
  "$(render "${OM[@]}" | yq ea 'select(.kind == "Secret" and .data.PIPELINE_SERVICE_CLIENT_ENABLED != null) | .data.PIPELINE_SERVICE_CLIENT_ENABLED | @base64d' | tr -d '"')"
check "openmetadata on: no openmetadata-db Secret by default" "" \
  "$(render "${OM[@]}" | yq 'select(.kind == "Secret" and .metadata.name == "openmetadata-db") | .metadata.name')"
must_fail "openmetadata-db create needs a password" "secrets.openmetadataDatabase.password is required" \
  "${OM[@]}" --set secrets.openmetadataDatabase.create=true
must_fail "openmetadata must not deploy its own MySQL" "openmetadata-dependencies.mysql.enabled must be false" \
  "${OM[@]}" --set openmetadata-dependencies.mysql.enabled=true
check "dev: openmetadata server references no Secret the release does not render" "" \
  "$(o=$(render "${DEV[@]}" "${OM[@]}"); comm -23 <(echo "$o" | yq ea 'select(.kind == "Deployment" and .metadata.name == "openmetadata") | [.spec.template.spec.initContainers[].env[]?, .spec.template.spec.containers[0].env[]?] | .[] | (.valueFrom.secretKeyRef.name // "")' | grep -v '^$' | sort -u) <(echo "$o" | yq ea 'select(.kind == "Secret") | .metadata.name' | sort -u) | paste -sd, -)"
check "dev: openmetadata-db Secret matches the naira chart's values-dev.yaml" "openmetadata-local-password" \
  "$(render "${DEV[@]}" "${OM[@]}" | yq 'select(.kind == "Secret" and .metadata.name == "openmetadata-db") | .stringData.password')"

# litellm sample models (values-dev.yaml)
LITELLM_CFG='select(.kind == "ConfigMap" and .metadata.name == "litellm-config") | .data["config.yaml"] | from_yaml'
check "dev: litellm routes a model to the local llama.cpp" "http://llama-qwen25-05b:8080/v1" \
  "$(render "${DEV[@]}" | yq "$LITELLM_CFG | .model_list[] | select(.model_name == \"idp-llama-qwen25-05b\") | .litellm_params.api_base")"
check "dev: litellm knows the mcp-mock server" "http://mcp-mock:8080/mcp" \
  "$(render "${DEV[@]}" | yq "$LITELLM_CFG | .mcp_servers.mock_kb.url")"
check "dev: every provider key the model list reads is in the Secret" "" \
  "$(o=$(render "${DEV[@]}"); comm -23 <(echo "$o" | yq "$LITELLM_CFG | .model_list[].litellm_params.api_key | select(. != null) | sub(\"os.environ/\"; \"\")" | sort -u) <(echo "$o" | yq 'select(.kind == "Secret" and .metadata.name == "litellm-provider-keys") | .stringData | keys | .[]' | sort -u) | paste -sd, -)"

# sample data Jobs
check "seed: no Jobs by default" "" \
  "$(render | yq ea 'select(.kind == "Job" and (.metadata.name | test("^seed-"))) | .metadata.name')"
# Named by a hash of spec and script, not .Release.Revision (always 1 under Argo)
SEEDS='[select(.kind == "Job" and (.metadata.name | test("^seed-"))) | .metadata.name] | sort | join(",")'
seeds() { render "$@" | yq ea "$SEEDS"; }
check "dev: mlflow seed Job, named by hash" "yes" \
  "$(seeds "${DEV[@]}" | grep -qE '^seed-mlflow-[0-9a-f]{8}$' && echo yes || echo no)"
check "seed: name is stable across renders" "$(seeds "${DEV[@]}")" "$(seeds "${DEV[@]}")"
check "seed: new name when the spec changes" "no" \
  "$([ "$(seeds "${DEV[@]}")" = "$(seeds "${DEV[@]}" --set seed.mlflow.image=x)" ] && echo yes || echo no)"
check "dev: mlflow seed reaches the mlflow Service" "http://mlflow:5000" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Job" and (.metadata.name | test("^seed-mlflow-"))) | .spec.template.spec.containers[0].env[] | select(.name == "MLFLOW_TRACKING_URI") | .value')"
check "mlflow: db-upgrade image is the server's" "$(render | yq 'select(.kind == "Deployment" and .metadata.name == "mlflow") | .spec.template.spec.containers[0].image')" \
  "$(render | yq 'select(.kind == "Deployment" and .metadata.name == "mlflow") | .spec.template.spec.initContainers[] | select(.name == "db-upgrade") | .image')"
check "seed: mlflow image is the subchart's" "$(render | yq 'select(.kind == "Deployment" and .metadata.name == "mlflow") | .spec.template.spec.containers[0].image')" \
  "$(yq '.seed.mlflow.image' "$CHART/values.yaml")"
check "seed: mlflow script is mounted" "yes" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "ConfigMap" and .metadata.name == "seed-mlflow") | .data["seed.py"]' | grep -q 'registered_model_name' && echo yes || echo no)"
check "dev+openmetadata: openmetadata seed Job" "yes" \
  "$(seeds "${DEV[@]}" "${OM[@]}" | grep -qE '^seed-mlflow-[0-9a-f]{8},seed-openmetadata-[0-9a-f]{8}$' && echo yes || echo no)"
check "seed: none for a component that is off" "" \
  "$(render "${DEV[@]}" --set tags.mlflow=false | yq ea 'select(.kind == "Job" and (.metadata.name | test("^seed-"))) | .metadata.name')"

# securityContext on the pods this chart defines (llama.cpp and vLLM excepted)
check "own pods run as non-root" "keycloak:true,mcp-mock:true,seed:true,seed:true" \
  "$(render "${DEV[@]}" "${OM[@]}" | yq ea '[select((.kind == "Deployment" or .kind == "Job") and (.metadata.name | test("^(keycloak|mcp-mock|seed-)"))) | .spec.template.spec.containers[] | .name + ":" + (.securityContext.runAsNonRoot | tostring)] | sort | join(",")')"

# observability: LiteLLM metrics scraping
MON=(--set tags.monitoring=true)
SM='select(.kind == "ServiceMonitor" and .metadata.name == "litellm") | .spec.endpoints[0]'
check "litellm requires auth on /metrics" "true" \
  "$(render | yq 'select(.kind == "ConfigMap" and .metadata.name == "litellm-config") | .data["config.yaml"]' | yq '.litellm_settings.require_auth_for_metrics_endpoint')"
check "litellm initializes budget metrics" "true" \
  "$(render | yq 'select(.kind == "ConfigMap" and .metadata.name == "litellm-config") | .data["config.yaml"]' | yq '.litellm_settings.prometheus_initialize_budget_metrics')"
check "dev: values-dev keeps the litellm_settings from values.yaml" "prometheus true" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "ConfigMap" and .metadata.name == "litellm-config") | .data["config.yaml"]' | yq '.litellm_settings.callbacks[0] + " " + (.litellm_settings.require_auth_for_metrics_endpoint | tostring)')"
check "litellm ServiceMonitor scrapes /metrics with the master key as bearer token" "/metrics litellm-masterkey masterkey" \
  "$(render "${MON[@]}" | yq "$SM | .path + \" \" + .authorization.credentials.name + \" \" + .authorization.credentials.key")"
check "litellm ServiceMonitor follows litellm.masterkeySecretName" "my-key my-field" \
  "$(render "${MON[@]}" --set litellm.masterkeySecretName=my-key --set litellm.masterkeySecretKey=my-field \
     | yq "$SM | .authorization.credentials.name + \" \" + .authorization.credentials.key")"
check "litellm image is pinned to the chart's version" "v1.84.0" \
  "$(render | yq "$LITELLM | .image | sub(\".*:\"; \"\")")"
check "litellm logs at INFO" "INFO" \
  "$(render | yq "$LITELLM | .env[] | select(.name == \"LITELLM_LOG\") | .value")"

# observability: Loki and Alloy come with tags.monitoring
check "loki and alloy off without monitoring" "" \
  "$(render | yq ea 'select((.kind == "StatefulSet" or .kind == "Deployment") and (.metadata.name == "loki" or (.metadata.name | test("alloy$")))) | .metadata.name')"
check "monitoring: loki and alloy rendered" "loki,t-alloy" \
  "$(render "${MON[@]}" | yq ea '[select((.kind == "StatefulSet" or .kind == "Deployment") and (.metadata.name == "loki" or (.metadata.name | test("alloy$")))) | .metadata.name] | sort | join(",")')"
check "loki runs single binary: one StatefulSet, no read/write/backend" "loki" \
  "$(render "${MON[@]}" | yq ea '[select(.kind == "StatefulSet" and (.metadata.name | test("^(loki|loki-read|loki-write|loki-backend)$"))) | .metadata.name] | join(",")')"
check "alloy pushes to loki's Service" "http://loki:3100/loki/api/v1/push" \
  "$(render "${MON[@]}" | yq ea 'select(.kind == "ConfigMap" and (.metadata.name | test("alloy$"))) | .data["config.alloy"]' | grep -o 'http://loki:3100/loki/api/v1/push' | head -1)"
check "alloy labels logs with namespace, pod, container and app" "4" \
  "$(render "${MON[@]}" | yq ea 'select(.kind == "ConfigMap" and (.metadata.name | test("alloy$"))) | .data["config.alloy"]' \
     | grep -cE 'target_label += "(namespace|pod|container)"|target_label += "app"' | awk '{print ($1 >= 4) ? 4 : $1}')"
check "grafana has a Loki datasource pointing at loki" "http://loki:3100" \
  "$(render "${MON[@]}" | yq ea 'select(.kind == "ConfigMap" and (.metadata.name | test("grafana-datasource"))) | .data["datasource.yaml"]' \
     | yq '.datasources[] | select(.name == "Loki") | .url')"

# observability: YACE (CloudWatch exporter)
YACE=("${MON[@]}" --set tags.yace=true)
must_fail "yace needs monitoring" "tags.yace needs tags.monitoring" \
  --set tags.yace=true
check "yace off by default" "" \
  "$(render "${MON[@]}" | yq ea 'select(.kind == "Deployment" and .metadata.name == "t-yace") | .metadata.name')"
check "yace on: Deployment rendered" "t-yace" \
  "$(render "${YACE[@]}" | yq ea 'select(.kind == "Deployment" and .metadata.name == "t-yace") | .metadata.name')"
check "yace: no AWS credentials Secret by default" "" \
  "$(render "${YACE[@]}" | yq ea 'select(.kind == "Secret" and .metadata.name == "yace-aws-credentials") | .metadata.name')"
check "yace: AWS credentials Secret when create=true" "AK SK" \
  "$(render "${YACE[@]}" --set secrets.yaceAws.create=true --set secrets.yaceAws.accessKey=AK --set secrets.yaceAws.secretKey=SK \
     | yq 'select(.kind == "Secret" and .metadata.name == "yace-aws-credentials") | .stringData.access_key + " " + .stringData.secret_key')"
check "yace: no AWS credentials Secret when yace is off" "" \
  "$(render "${MON[@]}" --set secrets.yaceAws.create=true --set secrets.yaceAws.accessKey=AK --set secrets.yaceAws.secretKey=SK \
     | yq ea 'select(.kind == "Secret" and .metadata.name == "yace-aws-credentials") | .metadata.name')"
must_fail "yace credentials create needs an access key" "secrets.yaceAws.accessKey is required" \
  "${YACE[@]}" --set secrets.yaceAws.create=true --set secrets.yaceAws.secretKey=SK
must_fail "yace credentials create needs a secret key" "secrets.yaceAws.secretKey is required" \
  "${YACE[@]}" --set secrets.yaceAws.create=true --set secrets.yaceAws.accessKey=AK
check "yace reads its credentials from yace-aws-credentials" "yace-aws-credentials" \
  "$(render "${YACE[@]}" | yq ea 'select(.kind == "Deployment" and .metadata.name == "t-yace") | .spec.template.spec.containers[0].env[] | select(.valueFrom.secretKeyRef.key == "access_key") | .valueFrom.secretKeyRef.name')"
check "yace ServiceMonitor from the chart, none from the subchart" "yace" \
  "$(render "${YACE[@]}" | yq ea '[select(.kind == "ServiceMonitor" and (.metadata.name | test("yace"))) | .metadata.name] | join(",")')"
check "yace ServiceMonitor carries the release label" "t" \
  "$(render "${YACE[@]}" | yq 'select(.kind == "ServiceMonitor" and .metadata.name == "yace") | .metadata.labels.release')"
check "yace ServiceMonitor selects the yace Service" "yace t" \
  "$(render "${YACE[@]}" | yq 'select(.kind == "ServiceMonitor" and .metadata.name == "yace") | .spec.selector.matchLabels["app.kubernetes.io/name"] + " " + .spec.selector.matchLabels["app.kubernetes.io/instance"]')"
check "yace ServiceMonitor selector matches a rendered Service" "1" \
  "$(render "${YACE[@]}" | yq ea '[select(.kind == "Service" and .metadata.labels["app.kubernetes.io/name"] == "yace" and .metadata.labels["app.kubernetes.io/instance"] == "t")] | length')"
check "no yace ServiceMonitor without tags.yace" "" \
  "$(render "${MON[@]}" | yq ea 'select(.kind == "ServiceMonitor" and .metadata.name == "yace") | .metadata.name')"
check "yace scrapes only AWS/Bedrock" "AWS/Bedrock" \
  "$(render "${YACE[@]}" | yq ea 'select(.kind == "ConfigMap" and (.metadata.name | test("yace"))) | .data["config.yml"]' | yq '.customNamespace[0].namespace')"
check "yace: scraping-interval is the cost knob, default 300" "true" \
  "$(render "${YACE[@]}" | yq 'select(.kind == "Deployment" and .metadata.name == "t-yace") | .spec.template.spec.containers[0].command | contains(["--scraping-interval=300"])')"
check "dev: yace stays off" "" \
  "$(render "${DEV[@]}" "${MON[@]}" | yq ea 'select(.kind == "Deployment" and .metadata.name == "t-yace") | .metadata.name')"
check "dev+monitoring+yace: two renders are identical" "yes" \
  "$(a=$(mktemp); b=$(mktemp); render "${DEV[@]}" "${YACE[@]}" --set secrets.yaceAws.create=true --set secrets.yaceAws.accessKey=AK --set secrets.yaceAws.secretKey=SK > "$a"
     render "${DEV[@]}" "${YACE[@]}" --set secrets.yaceAws.create=true --set secrets.yaceAws.accessKey=AK --set secrets.yaceAws.secretKey=SK > "$b"
     cmp -s "$a" "$b" && echo yes || echo no; rm -f "$a" "$b")"

# Every ci/ fixture must still render
for f in "$CHART"/ci/*-values.yaml; do
  check "ci/$(basename "$f") renders" "ok" \
    "$(helm template ci "$CHART" --namespace naira-deps -f "$f" >/dev/null 2>&1 && echo ok || echo "FAILED to render")"
done

exit $fail
