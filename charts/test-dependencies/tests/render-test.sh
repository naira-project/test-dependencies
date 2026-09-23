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
check "dev: mcp-mock off until its image is published (TD2)" "" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Deployment" and .metadata.name == "mcp-mock") | .metadata.name')"
check "dev: masterkey Secret created" "sk-local-litellm" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Secret" and .metadata.name == "litellm-masterkey") | .stringData.masterkey')"
check "dev: provider keys Secret created" "litellm-provider-keys" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Secret" and .metadata.name == "litellm-provider-keys") | .metadata.name')"
n=$(render "${DEV[@]}" | grep -c 'localhost:5001' || true)   # grep exits 1 on no match
check "dev: no image points at the PoC registry" "0" "${n:-0}"
a=$(mktemp); b=$(mktemp); render "${DEV[@]}" > "$a"; render "${DEV[@]}" > "$b"
check "dev: two renders are identical" "yes" "$(cmp -s "$a" "$b" && echo yes || echo no)"
rm -f "$a" "$b"

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
check "openmetadata on: mysql-secrets when create=true" "pw1" \
  "$(render "${OM[@]}" --set secrets.openmetadataMysql.create=true --set secrets.openmetadataMysql.password=pw1 | yq 'select(.kind == "Secret" and .metadata.name == "mysql-secrets") | .stringData["openmetadata-mysql-password"]')"
must_fail "openmetadata mysql Secret create rejects an empty password" "secrets.openmetadataMysql.password is required" \
  "${OM[@]}" --set secrets.openmetadataMysql.create=true --set secrets.openmetadataMysql.password=""
check "dev: openmetadata server references no Secret the release does not render" "" \
  "$(o=$(render "${DEV[@]}" "${OM[@]}"); comm -23 <(echo "$o" | yq ea 'select(.kind == "Deployment" and .metadata.name == "openmetadata") | [.spec.template.spec.initContainers[].env[]?, .spec.template.spec.containers[0].env[]?] | .[] | (.valueFrom.secretKeyRef.name // "")' | grep -v '^$' | sort -u) <(echo "$o" | yq ea 'select(.kind == "Secret") | .metadata.name' | sort -u) | paste -sd, -)"
check "dev: mysql-secrets equals the password in the MySQL init script" "yes" \
  "$(o=$(render "${DEV[@]}" "${OM[@]}"); a=$(echo "$o" | yq 'select(.kind == "Secret" and .metadata.name == "mysql-secrets") | .stringData["openmetadata-mysql-password"]'); b=$(echo "$o" | yq ea 'select(.kind == "ConfigMap" and .metadata.name == "mysql-init-scripts") | .data["init_openmetadata_db_scripts.sql"]' | sed -n "s/.*openmetadata_user'@'%' IDENTIFIED BY '\([^']*\)'.*/\1/p"); [ -n "$a" ] && [ "$a" = "$b" ] && echo yes || echo "no ($a vs $b)")"

exit $fail
