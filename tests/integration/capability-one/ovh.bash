#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

: "${CROSSPLANE_OVH_PROJECT_ID:?Set the project ID used by ovh/dependencies/iam.sh.}"
: "${CROSSPLANE_OVH_STORAGE_REGION:=de}"
if [[ ! "${CROSSPLANE_OVH_PROJECT_ID}" =~ ^[0-9a-f]{32}$ ]]; then
  printf 'CROSSPLANE_OVH_PROJECT_ID must be a 32-character lowercase hexadecimal ID.\n' >&2
  exit 1
fi
case "${CROSSPLANE_OVH_STORAGE_REGION}" in
  de|gra) ;;
  *) printf 'CROSSPLANE_OVH_STORAGE_REGION must be de or gra.\n' >&2; exit 1 ;;
esac

story_environment=storage-ovh
story_rclone_provider=OVHcloud

story_configure_run() {
  story_prefix="xyz-ovh-${CROSSPLANE_OVH_PROJECT_ID:0:12}-${CROSSPLANE_OVH_STORAGE_REGION}-${story_run_id}"
  story_composition_provider=ovh-capability-one
  validate_resource_prefix story_prefix "${story_prefix}"
}

story_bucket() {
  printf '%s-%s\n' "${story_prefix}" "$1"
}

story_identity() {
  printf '%s-%s\n' "${story_prefix}" "$1"
}

story_bucket_exists() {
  kube get projectstorage.cloud.ovh.m.edixos.io/"$1" \
    -n "${story_namespace}" >/dev/null 2>&1
}

story_capture_managed() {
  local principal="$1" directory="$2" owner_id candidate
  case "${principal}" in
    s-joe) owner_id=12345 ;;
    s-jeff) owner_id=12346 ;;
    s-jane) owner_id=12347 ;;
    s-john) owner_id=12348 ;;
    *) printf 'Unknown story principal: %s\n' "${principal}" >&2; return 1 ;;
  esac
  candidate="${directory}/managed-${principal}.json"
  kube get \
    users.cloud.ovh.m.edixos.io,s3credentials.cloud.ovh.m.edixos.io,s3policies.cloud.ovh.m.edixos.io,projectstorages.cloud.ovh.m.edixos.io \
    -n "${story_namespace}" -l "crossplane.io/composite=${principal}" -o json |
    jq --arg prefix "${story_prefix}" --arg principal "${principal}" \
      --arg owner_id "${owner_id}" '
      [.items[] |
        (.metadata.annotations["crossplane.io/composition-resource-name"] // .metadata.name) as $key |
        {apiVersion,kind,
          metadata:{name:.metadata.name,namespace:"default",
            annotations:{"crossplane.io/composition-resource-name":$key}},
          status:{conditions:[.status.conditions[]? | {type,status,reason}],
            atProvider:(if .kind == "User" and $key == ("owner-" + $principal)
              then {id:$owner_id}
              elif .kind == "S3Credentials"
              then {accessKeyId:"EXAMPLEACCESSKEY"}
              else {} end)}} |
        walk(if type == "string" then gsub($prefix;"xyz-story-fixture") else . end)]' \
      >"${candidate}"
  jq -s 'add' "${directory}/observed-${principal}.json" "${candidate}" \
    >"${directory}/observed-${principal}.json.tmp"
  mv "${directory}/observed-${principal}.json.tmp" \
    "${directory}/observed-${principal}.json"
  rm "${candidate}"
}

story_setup() {
  require_command yq
  require_command ovhcloud
  if [[ "$(ovhcloud cloud project get "${CROSSPLANE_OVH_PROJECT_ID}" --output id)" != \
    "${CROSSPLANE_OVH_PROJECT_ID}" ]]; then
    printf 'The OVHcloud CLI login cannot read the selected project.\n' >&2
    return 1
  fi
  if ! kube get secret/ovh-provider-creds -n "${INTEGRATION_NAMESPACE}" \
    -o name >/dev/null 2>&1; then
    printf 'The OVHcloud provider credential Secret is missing in %s.\n' \
      "${INTEGRATION_NAMESPACE}" >&2
    return 1
  fi
  kube get environmentconfig.apiextensions.crossplane.io/"${story_environment}" \
    -o json | jq -e --arg project "${CROSSPLANE_OVH_PROJECT_ID}" \
      --arg region "${CROSSPLANE_OVH_STORAGE_REGION}" '
        .data.storage.serviceName == $project and
        .data.storage.region == $region and
        .data.storage.endpoint == ("https://s3." + $region + ".io.cloud.ovh.net")
      ' >/dev/null || {
    printf 'The installed OVHcloud EnvironmentConfig does not match this project and region.\n' >&2
    return 1
  }
  kube wait provider.pkg.crossplane.io/provider-ovh \
    --for=condition=Healthy --timeout=5m
  kube wait provider.pkg.crossplane.io/provider-kubernetes \
    --for=condition=Healthy --timeout=5m
  kube get compositeresourcedefinition.apiextensions.crossplane.io/storages.pkg.internal \
    >/dev/null

  kube create namespace "${story_namespace}"
  kube get secret/ovh-provider-creds -n "${INTEGRATION_NAMESPACE}" -o json |
    jq --arg namespace "${story_namespace}" '
      {apiVersion:"v1",kind:"Secret",
       metadata:{name:"ovh-provider-creds",namespace:$namespace},
       type,data}' | kube apply -f -
  cat <<EOF | kube apply -f -
apiVersion: ovh.m.edixos.io/v1beta1
kind: ProviderConfig
metadata:
  name: provider-ovh
  namespace: ${story_namespace}
spec:
  credentials:
    source: Secret
    secretRef:
      name: ovh-provider-creds
      namespace: ${story_namespace}
      key: credentials
---
apiVersion: kubernetes.m.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: provider-kubernetes
  namespace: ${story_namespace}
spec:
  credentials:
    source: InjectedIdentity
EOF
  yq eval '.metadata.name = "storage-ovh-capability-one" |
    .metadata.labels.provider = "ovh-capability-one"' \
    "${REPO_ROOT}/ovh/composition.yaml" | kube apply -f -
}
