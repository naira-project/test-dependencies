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
  "$(render --set tags.llamacpp=true | yq ea 'select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("^llama"))) | .metadata.name')"
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

# langfuse: one upstream chart, the three stores it brings, a ClickHouse this
# chart renders, and credentials that must not be generated. The tag is off
# everywhere, so every check turns it on.
LF=(--set tags.langfuse=true)
check "langfuse off by default" "" \
  "$(render | yq ea '[select((.kind == "Deployment" or .kind == "StatefulSet") and (.metadata.name | test("^langfuse|^clickhouse"))) | .metadata.name] | join(",")')"
must_fail "langfuse: each store password is required" "langfuse.postgresql.auth.password is required" \
  "${LF[@]}"
# With the tag on, values-dev.yaml supplies the rest.
DEVLF=("${DEV[@]}" "${LF[@]}")
LFWEB='select(.kind == "Deployment" and .metadata.name == "langfuse-web") | .spec.template.spec.containers[0]'
check "dev+langfuse: web, worker and the three bundled stores" \
  "langfuse-postgresql,langfuse-s3-all-in-one,langfuse-valkey,langfuse-web,langfuse-worker" \
  "$(render "${DEVLF[@]}" | yq ea '[select((.kind == "Deployment" or .kind == "StatefulSet") and (.metadata.name | test("^langfuse"))) | .metadata.name] | sort | join(",")')"
check "dev+langfuse: ClickHouse is this chart's own StatefulSet" "clickhouse" \
  "$(render "${DEVLF[@]}" | yq ea 'select(.kind == "StatefulSet" and .metadata.name == "clickhouse") | .metadata.name')"
# The whole point of rendering it here: no operator, so no CRs and no CRDs.
check "dev+langfuse: nothing needs the ClickHouse operator" "0" \
  "$(render "${DEVLF[@]}" | yq ea '[select(.apiVersion == "clickhouse.com/v1alpha1")] | length')"
check "dev+langfuse: ClickHouse serves HTTP and native on one Service" "8123,9000" \
  "$(render "${DEVLF[@]}" | yq ea '[select(.kind == "Service" and .metadata.name == "clickhouse") | .spec.ports[].port] | sort | join(",")')"
check "dev+langfuse: the data volume is handed to the image's uid" \
  "$(yq '.clickhouse.uid' "$CHART/values.yaml")" \
  "$(render "${DEVLF[@]}" | yq ea 'select(.kind == "StatefulSet" and .metadata.name == "clickhouse") | .spec.template.spec.securityContext.fsGroup')"
# Server and client read one Secret, so no two copies of the password exist.
CHSECRET='select(.kind == "StatefulSet" and .metadata.name == "clickhouse") | .spec.template.spec.containers[0].env[] | select(.name == "CLICKHOUSE_PASSWORD") | .valueFrom.secretKeyRef'
check "dev+langfuse: the server reads the password from clickhouse-auth" "clickhouse-auth/password" \
  "$(render "${DEVLF[@]}" | yq ea "$CHSECRET | .name + \"/\" + .key")"
check "dev+langfuse: Langfuse reads the very same Secret" "clickhouse-auth/password" \
  "$(render "${DEVLF[@]}" | yq "$LFWEB | .env[] | select(.name == \"CLICKHOUSE_PASSWORD\") | .valueFrom.secretKeyRef | .name + \"/\" + .key")"
check "dev+langfuse: Langfuse connects to the in-chart Service" "http://clickhouse:8123" \
  "$(render "${DEVLF[@]}" | yq "$LFWEB | .env[] | select(.name == \"CLICKHOUSE_URL\") | .value")"
check "langfuse: no clickhouse-auth Secret by default" "" \
  "$(render "${LF[@]}" -f "$CHART/values-dev.yaml" --set secrets.clickhouseAuth.create=false \
     | yq ea 'select(.kind == "Secret" and .metadata.name == "clickhouse-auth") | .metadata.name')"
# Each bundled store can be swapped for one that already exists. The password
# guards must follow the store: required while this chart deploys it, and out
# of the way once it does not.
PGEXT=(--set langfuse.postgresql.deploy=false --set langfuse.postgresql.host=pg.example.internal
       --set langfuse.postgresql.auth.password= --set langfuse.postgresql.auth.existingSecret=langfuse-db
       --set langfuse.postgresql.auth.secretKeys.userPasswordKey=password)
check "postgres: deploy=false renders no PostgreSQL of its own" "0" \
  "$(render "${DEVLF[@]}" "${PGEXT[@]}" | yq ea '[select(.metadata.name == "langfuse-postgresql")] | length')"
check "postgres: Langfuse is pointed at the external host" "pg.example.internal" \
  "$(render "${DEVLF[@]}" "${PGEXT[@]}" | yq "$LFWEB | .env[] | select(.name == \"DATABASE_HOST\") | .value")"
check "postgres: external credentials come from the operator's Secret" "langfuse-db/password" \
  "$(render "${DEVLF[@]}" "${PGEXT[@]}" | yq "$LFWEB | .env[] | select(.name == \"DATABASE_PASSWORD\") | .valueFrom.secretKeyRef | .name + \"/\" + .key")"
must_fail "postgres: an external server must be named" "langfuse.postgresql.host is required" \
  "${DEVLF[@]}" --set langfuse.postgresql.deploy=false --set langfuse.postgresql.host=
# AWS: endpoint deliberately empty so the SDK resolves it from the region, and
# no keys at all because the pod authenticates through its role.
S3AWS=(--set langfuse.s3.deploy=false --set langfuse.s3.auth.rootPassword=
       --set langfuse.s3.bucket=naira-langfuse --set langfuse.s3.region=eu-central-1
       --set langfuse.s3.forcePathStyle=false)
check "s3: deploy=false renders no SeaweedFS of its own" "0" \
  "$(render "${DEVLF[@]}" "${S3AWS[@]}" | yq ea '[select(.metadata.name == "langfuse-s3-all-in-one")] | length')"
check "s3: AWS bucket, region and path style reach the pods" "naira-langfuse,eu-central-1,false" \
  "$(render "${DEVLF[@]}" "${S3AWS[@]}" | yq ea "[$LFWEB | .env[] | select(.name | test(\"S3_EVENT_UPLOAD_(BUCKET|REGION|FORCE_PATH_STYLE)\$\")) | .value] | join(\",\")")"
check "s3: no endpoint is set for AWS, so the SDK resolves one" "0" \
  "$(render "${DEVLF[@]}" "${S3AWS[@]}" | yq ea "[$LFWEB | .env[] | select(.name == \"LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT\")] | length")"
check "s3: an S3-compatible endpoint takes credentials by reference" "http://minio.storage.svc:9000,langfuse-s3/access-key-id" \
  "$(render "${DEVLF[@]}" "${S3AWS[@]}" --set langfuse.s3.endpoint=http://minio.storage.svc:9000 \
       --set langfuse.s3.accessKeyId.secretKeyRef.name=langfuse-s3 --set langfuse.s3.accessKeyId.secretKeyRef.key=access-key-id \
     | yq ea "[$LFWEB | .env[] | select(.name == \"LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT\") | .value, $LFWEB | .env[] | select(.name == \"LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID\") | .valueFrom.secretKeyRef | .name + \"/\" + .key] | join(\",\")")"
# An adopter with their own ClickHouse drops ours and keeps the rest.
check "langfuse: clickhouse.deploy=false drops the server, keeps Langfuse" "langfuse-web" \
  "$(render "${DEVLF[@]}" --set clickhouse.deploy=false --set langfuse.clickhouse.host=ch.example.svc \
     | yq ea '[select(.kind == "StatefulSet" and .metadata.name == "clickhouse") | .metadata.name, select(.kind == "Deployment" and .metadata.name == "langfuse-web") | .metadata.name] | join(",")')"
must_fail "clickhouse: user must match what Langfuse authenticates as" "must match" \
  "${DEVLF[@]}" --set clickhouse.user=analytics
must_fail "clickhouse: database must match the one Langfuse opens" "must match" \
  "${DEVLF[@]}" --set clickhouse.database=traces
# The subchart's ClickHouse hits its own CRD preflight first — the operator is
# missing, which is why ours exists. Past that, our guard catches the pair.
must_fail "clickhouse: the operator's ClickHouse still demands the operator" "ClickHouse operator CRDs not found" \
  "${DEVLF[@]}" --set langfuse.clickhouse.deploy=true
must_fail "clickhouse: this chart's server and the operator's are exclusive" "enable one, not both" \
  "${DEVLF[@]}" --set langfuse.clickhouse.deploy=true --set langfuse.clickhouse.crdCheck=false
must_fail "clickhouse: deploying ours means addressing ours" "set clickhouse.deploy=false" \
  "${DEVLF[@]}" --set langfuse.clickhouse.host=elsewhere
# litellm's bundled PostgreSQL is <release>-postgresql; langfuse's would be too.
check "dev+langfuse: no two objects share a kind and a name" "" \
  "$(render "${DEVLF[@]}" | yq ea '[select(.kind != null) | .kind + "/" + .metadata.name] | .[]' | sort | uniq -d | paste -sd, -)"
check "langfuse: SALT comes from the chart's Secret, never generated" "langfuse-app-credentials" \
  "$(render "${DEVLF[@]}" | yq "$LFWEB | .env[] | select(.name == \"SALT\") | .valueFrom.secretKeyRef.name")"
check "langfuse: the app credentials Secret is not created by default" "" \
  "$(render "${LF[@]}" -f "$CHART/values-dev.yaml" --set secrets.langfuseApp.create=false \
     | yq ea 'select(.kind == "Secret" and .metadata.name == "langfuse-app-credentials") | .metadata.name')"
check "dev+langfuse: the app credentials Secret outlives the release" "keep" \
  "$(render "${DEVLF[@]}" | yq ea 'select(.kind == "Secret" and .metadata.name == "langfuse-app-credentials") | .metadata.annotations["helm.sh/resource-policy"]')"
must_fail "langfuse app Secret create needs a salt" "secrets.langfuseApp.salt is required" \
  "${DEVLF[@]}" --set secrets.langfuseApp.salt=""
check "dev+langfuse: web reaches its own PostgreSQL, not litellm's" "langfuse-postgresql" \
  "$(render "${DEVLF[@]}" | yq "$LFWEB | .env[] | select(.name == \"DATABASE_HOST\") | .value")"
check "dev+langfuse: Langfuse does not phone home" "false" \
  "$(render "${DEVLF[@]}" | yq "$LFWEB | .env[] | select(.name == \"TELEMETRY_ENABLED\") | .value")"
# Everything pinnable is pinned; seaweedfs generates its SFTP credentials with
# no values hook to stop it (see the s3 block in values.yaml).
a=$(mktemp); b=$(mktemp); render "${DEVLF[@]}" > "$a"; render "${DEVLF[@]}" > "$b"
changed=""
for n in $(yq ea '[select(.kind == "Secret") | .metadata.name] | .[]' "$a"); do
  q="select(.kind == \"Secret\" and .metadata.name == \"$n\") | (.data // .stringData)"
  [ "$(yq "$q" "$a" | cksum)" = "$(yq "$q" "$b" | cksum)" ] || changed="$changed$n "
done
check "dev+langfuse: renders differ only in seaweedfs's unused SFTP Secret" \
  "langfuse-s3-sftp-secret " "$changed"
rm -f "$a" "$b"

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
check "dev: mlflow seed Job, named per revision" "seed-mlflow-1" \
  "$(render "${DEV[@]}" | yq ea 'select(.kind == "Job" and (.metadata.name | test("^seed-"))) | .metadata.name')"
check "dev: mlflow seed reaches the mlflow Service" "http://mlflow:5000" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "Job" and .metadata.name == "seed-mlflow-1") | .spec.template.spec.containers[0].env[] | select(.name == "MLFLOW_TRACKING_URI") | .value')"
check "seed: mlflow image is the subchart's" "$(render | yq 'select(.kind == "Deployment" and .metadata.name == "mlflow") | .spec.template.spec.containers[0].image')" \
  "$(yq '.seed.mlflow.image' "$CHART/values.yaml")"
check "seed: mlflow script is mounted" "yes" \
  "$(render "${DEV[@]}" | yq 'select(.kind == "ConfigMap" and .metadata.name == "seed-mlflow") | .data["seed.py"]' | grep -q 'registered_model_name' && echo yes || echo no)"
check "dev+openmetadata: openmetadata seed Job" "seed-mlflow-1,seed-openmetadata-1" \
  "$(render "${DEV[@]}" "${OM[@]}" | yq ea '[select(.kind == "Job" and (.metadata.name | test("^seed-"))) | .metadata.name] | sort | join(",")')"
check "seed: none for a component that is off" "" \
  "$(render "${DEV[@]}" --set tags.mlflow=false | yq ea 'select(.kind == "Job" and (.metadata.name | test("^seed-"))) | .metadata.name')"

# Every ci/ fixture must keep rendering against this chart's guards (the PoC
# values drifted from the chart once already).
for f in "$CHART"/ci/*-values.yaml; do
  check "ci/$(basename "$f") renders" "ok" \
    "$(helm template ci "$CHART" --namespace naira-deps -f "$f" >/dev/null 2>&1 && echo ok || echo "FAILED to render")"
done

exit $fail
