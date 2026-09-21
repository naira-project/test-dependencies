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

exit $fail
