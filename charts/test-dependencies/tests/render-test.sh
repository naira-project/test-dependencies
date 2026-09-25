#!/usr/bin/env bash
# Render assertions for the test-dependencies chart.
# Needs helm and mikefarah yq v4. Run `helm dependency build` on the chart first.
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

# Bare defaults do not render: secrets.litellmPostgres.password is required.
render() { helm template t "$CHART" --namespace deps --set litellm.postgresql.auth.password=test-pg --set litellm.postgresql.auth.postgres-password=test-pg "$@"; }

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

# bitnami PostgreSQL must not render its own (random) Secret
check "postgres reuses litellm-dbcredentials" "" \
  "$(render | yq 'select(.kind == "Secret" and (.metadata.name | test("postgresql"))) | .metadata.name')"
# Only mlflow's flask key may differ between two default renders (see Global Constraints)
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
check "dev: no image points at the PoC registry" "0" "${n:-0}"
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
check "dev: postgres image is pinned" "registry-1.docker.io/bitnamilegacy/postgresql:17.6.0-debian-12-r4" \
  "$(render "${DEV[@]}" | yq ea 'select(.kind == "StatefulSet" and (.metadata.name | test("postgresql"))) | .spec.template.spec.containers[0].image')"
check "dev: postgres password is the configured one, not the upstream sample" "litellm-local-postgres" \
  "$(helm template t "$CHART" --namespace deps "${DEV[@]}" | yq ea 'select(.kind == "Secret" and .metadata.name == "litellm-dbcredentials") | .data.password' | base64 -d)"
must_fail "postgres password required" "litellm.postgresql.auth.password is required" \
  --set litellm.postgresql.auth.password=""
must_fail "postgres password must not be the upstream sample" "must not be the litellm-helm sample" \
  --set litellm.postgresql.auth.postgres-password=NoTaGrEaTpAsSwOrD

# keycloak admin Secret
must_fail "keycloak admin create needs a username" "keycloak.admin.username is required" \
  --set keycloak.admin.create=true --set keycloak.admin.password=x
must_fail "keycloak admin create needs a password" "keycloak.admin.password is required" \
  --set keycloak.admin.create=true --set keycloak.admin.username=x
must_fail "keycloak admin: existing and create" "keycloak.admin: set existingSecret or create, not both" \
  --set keycloak.admin.create=true --set keycloak.admin.existingSecret=x --set keycloak.admin.username=x --set keycloak.admin.password=x
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
check "llamacpp: one shared model cache PVC" "llamacpp-model-cache" \
  "$(render --set tags.llamacpp=true | yq ea 'select(.kind == "PersistentVolumeClaim") | .metadata.name')"
check "llamacpp: Services are labelled as inference" "llama-dummy-model,llama-qwen25-05b" \
  "$(render --set tags.llamacpp=true | yq ea '[select(.kind == "Service" and .metadata.labels["app.kubernetes.io/component"] == "inference") | .metadata.name] | sort | join(",")')"
check "llamacpp: models come from values" "llama-only" \
  "$(render --set tags.llamacpp=true --set-json 'llamacpp.models=[{"name":"llama-only","modelFile":"m.gguf","downloadUrl":"https://example.invalid/m.gguf","resources":{}}]' | yq ea 'select(.kind == "Deployment" and .metadata.name == "llama-*") | .metadata.name')"
check "llamacpp: off by default" "" \
  "$(render | yq ea 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "llamacpp-model-cache") | .metadata.name')"
VLLM='select(.kind == "Deployment" and .metadata.name == "vllm") | .spec.template.spec.containers[0]'
check "vllm: container port is vLLM's own 8000" "8000" \
  "$(render --set tags.vllm=true | yq "$VLLM | .ports[0].containerPort")"
check "vllm: Service targets the named port" "8000" \
  "$(render --set tags.vllm=true | yq 'select(.kind == "Service" and .metadata.name == "vllm") | .spec.ports[0].port')"
check "vllm: serves the configured model name" "opt-125m" \
  "$(render --set tags.vllm=true | yq "$VLLM | .args[2]")"
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

# openmetadata: server + its dependencies (MySQL, OpenSearch) ride one tag; Airflow stays off
OM=(--set tags.openmetadata=true)
check "openmetadata off by default" "" \
  "$(render | yq 'select(.kind == "Deployment" and .metadata.name == "openmetadata") | .metadata.name')"
check "openmetadata on: server, mysql, opensearch rendered" "mysql,openmetadata,opensearch" \
  "$(render "${OM[@]}" | yq ea '[select((.kind == "Deployment" or .kind == "StatefulSet") and (.metadata.name == "openmetadata" or .metadata.name == "mysql" or .metadata.name == "opensearch")) | .metadata.name] | sort | join(",")')"
check "openmetadata on: no airflow" "0" \
  "$(render "${OM[@]}" | yq ea '[select(.kind == "Deployment" or .kind == "StatefulSet") | .metadata.name | select(test("airflow"))] | length')"
check "openmetadata on: pipeline service client disabled" "false" \
  "$(render "${OM[@]}" | yq ea 'select(.kind == "Secret" and .data.PIPELINE_SERVICE_CLIENT_ENABLED != null) | .data.PIPELINE_SERVICE_CLIENT_ENABLED | @base64d' | tr -d '"')"
check "openmetadata on: no mysql-secrets by default" "" \
  "$(render "${OM[@]}" | yq 'select(.kind == "Secret" and .metadata.name == "mysql-secrets") | .metadata.name')"
must_fail "openmetadata: Secret password must match the init script" "does not match the password in openmetadata-dependencies.mysql.initdbScripts" \
  "${OM[@]}" --set secrets.openmetadataMysql.create=true --set secrets.openmetadataMysql.password=pw1
must_fail "openmetadata mysql Secret create rejects an empty password" "secrets.openmetadataMysql.password" \
  "${OM[@]}" --set secrets.openmetadataMysql.create=true --set secrets.openmetadataMysql.password=""
check "dev: openmetadata server references no Secret the release does not render" "" \
  "$(o=$(render "${DEV[@]}" "${OM[@]}"); comm -23 <(echo "$o" | yq ea 'select(.kind == "Deployment" and .metadata.name == "openmetadata") | [.spec.template.spec.initContainers[].env[]?, .spec.template.spec.containers[0].env[]?] | .[] | (.valueFrom.secretKeyRef.name // "")' | grep -v '^$' | sort -u) <(echo "$o" | yq ea 'select(.kind == "Secret") | .metadata.name' | sort -u) | paste -sd, -)"
check "dev: mysql-secrets equals the password in the MySQL init script" "yes" \
  "$(o=$(render "${DEV[@]}" "${OM[@]}"); a=$(echo "$o" | yq 'select(.kind == "Secret" and .metadata.name == "mysql-secrets") | .stringData["openmetadata-mysql-password"]'); b=$(echo "$o" | yq ea 'select(.kind == "ConfigMap" and .metadata.name == "mysql-init-scripts") | .data["init_openmetadata_db_scripts.sql"]' | sed -n "s/.*openmetadata_user'@'%' IDENTIFIED BY '\([^']*\)'.*/\1/p"); [ -n "$a" ] && [ "$a" = "$b" ] && echo yes || echo "no ($a vs $b)")"

# The ArgoCD PoC Application must keep rendering against this chart's guards
# (its valuesObject drifted from the chart once already).
POC="$CHART/../../argocd/environments/poc/test-dependencies.yaml"
poc_values=$(mktemp); yq '.spec.source.helm.valuesObject' "$POC" > "$poc_values"
poc_vf=$(yq '.spec.source.helm.valueFiles[0] // ""' "$POC")
check "argocd PoC Application values render" "ok" \
  "$(helm template poc "$CHART" --namespace naira-deps ${poc_vf:+-f "$CHART/$poc_vf"} -f "$poc_values" >/dev/null 2>&1 && echo ok || echo "FAILED to render")"
rm -f "$poc_values"

exit $fail
