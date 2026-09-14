#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

cleanup_ovh() {
  : "${CROSSPLANE_OVH_PROJECT_ID:?Set the project ID used by ovh/dependencies/iam.sh.}"
  : "${CROSSPLANE_OVH_STORAGE_REGION:=de}"
  require_command ovhcloud
  if [[ ! "${CROSSPLANE_OVH_PROJECT_ID}" =~ ^[0-9a-f]{32}$ ]]; then
    printf 'CROSSPLANE_OVH_PROJECT_ID must be a lowercase 32-character hexadecimal ID.\n' >&2
    return 1
  fi
  case "${CROSSPLANE_OVH_STORAGE_REGION}" in
    de|gra) ;;
    *) printf 'CROSSPLANE_OVH_STORAGE_REGION must be de or gra.\n' >&2; return 1 ;;
  esac

  local run_id="${story_namespace#xyz-story-ovh-}"
  local prefix="xyz-ovh-${CROSSPLANE_OVH_PROJECT_ID:0:12}-${CROSSPLANE_OVH_STORAGE_REGION}-${run_id}"
  local bucket user_id deadline remaining active_users
  local -a buckets=()
  if ! kube get storages.pkg.internal -n "${story_namespace}" \
    -l storages.pkg.internal/capability-one=true -o json |
    jq -e --arg prefix "${prefix}-" '
      all(.items[];
        (.spec.providerIdentity | startswith($prefix)) and
        all(.spec.buckets[]?; .bucketName | startswith($prefix)))' >/dev/null; then
    printf 'Story identities or bucket names do not match %s.\n' "${prefix}" >&2
    return 1
  fi
  mapfile -t buckets < <(
    kube get storages.pkg.internal -n "${story_namespace}" \
      -l storages.pkg.internal/capability-one=true -o json |
      jq -r '.items[] | .spec.buckets[]?.bucketName' | sort -u
  )

  for bucket in "${buckets[@]}"; do
    ovhcloud cloud storage object bucket get "${bucket}" \
      --cloud-project "${CROSSPLANE_OVH_PROJECT_ID}" --output json |
      jq -e --arg bucket "${bucket}" '.name == $bucket' >/dev/null
    ovhcloud cloud storage object bucket bulk-delete "${bucket}" \
      --prefix story/ --cloud-project "${CROSSPLANE_OVH_PROJECT_ID}" \
      --output json >/dev/null
    deadline=$((SECONDS + 300))
    until ovhcloud cloud storage object bucket object list "${bucket}" \
      --cloud-project "${CROSSPLANE_OVH_PROJECT_ID}" --output json |
      jq -e '. == null or . == []' >/dev/null; do
      if ((SECONDS >= deadline)); then
        printf 'Bucket %s is not empty after removing story objects.\n' "${bucket}" >&2
        return 1
      fi
      sleep 10
    done
    printf 'Emptied OVHcloud story bucket %s\n' "${bucket}"
  done

  log 'Deleting OVHcloud story claims before retained project buckets'
  kube delete storages.pkg.internal -n "${story_namespace}" \
    -l storages.pkg.internal/capability-one=true --wait=false
  deadline=$((SECONDS + 600))
  while [[ -n "$(kube get \
    users.cloud.ovh.m.edixos.io,s3credentials.cloud.ovh.m.edixos.io,s3policies.cloud.ovh.m.edixos.io,projectstorages.cloud.ovh.m.edixos.io,objects.kubernetes.m.crossplane.io \
    -n "${story_namespace}" -o name)" ]]; do
    remaining="$(kube get \
      users.cloud.ovh.m.edixos.io,s3credentials.cloud.ovh.m.edixos.io,s3policies.cloud.ovh.m.edixos.io,projectstorages.cloud.ovh.m.edixos.io,objects.kubernetes.m.crossplane.io \
      -n "${story_namespace}" -o json)"
    # The provider can leave S3Credentials finalizers when Crossplane deletes
    # their parent cloud users first. Release only credentials whose parent
    # users are confirmed absent from the target project.
    if jq -e --arg namespace "${story_namespace}" '
      (.items | length) > 0 and all(.items[];
        .kind == "S3Credentials" and
        .metadata.namespace == $namespace and
        .metadata.deletionTimestamp != null and
        (.spec.forProvider.userId | type == "string" and test("^[0-9]+$")))' \
      <<<"${remaining}" >/dev/null; then
      active_users="$(ovhcloud cloud user list \
        --cloud-project "${CROSSPLANE_OVH_PROJECT_ID}" --output json |
        jq '[.[].id]')"
      if jq -e --argjson active "${active_users}" '
        all(.items[]; (.spec.forProvider.userId | tonumber) as $id |
          ($active | index($id)) == null))' <<<"${remaining}" >/dev/null; then
        while IFS= read -r credential; do
          kube patch s3credentials.cloud.ovh.m.edixos.io/"${credential}" \
            -n "${story_namespace}" --type=merge \
            -p '{"metadata":{"finalizers":[]}}'
        done < <(jq -r '.items[].metadata.name' <<<"${remaining}")
      fi
    fi
    if ((SECONDS >= deadline)); then
      printf 'OVHcloud composed resources did not finish deleting in %s.\n' \
        "${story_namespace}" >&2
      return 1
    fi
    sleep 5
  done

  for bucket in "${buckets[@]}"; do
    ovhcloud cloud storage object bucket delete "${bucket}" \
      --cloud-project "${CROSSPLANE_OVH_PROJECT_ID}" --output json >/dev/null
    printf 'Deleted OVHcloud story bucket %s\n' "${bucket}"
  done

  while IFS= read -r user_id; do
    [[ -z "${user_id}" ]] && continue
    [[ "${user_id}" =~ ^[0-9]+$ ]] || {
      printf 'Unexpected OVHcloud story user ID.\n' >&2
      return 1
    }
    ovhcloud cloud user delete "${user_id}" \
      --cloud-project "${CROSSPLANE_OVH_PROJECT_ID}" --output json >/dev/null
    printf 'Deleted retained OVHcloud story user %s\n' "${user_id}"
  done < <(
    ovhcloud cloud user list --cloud-project "${CROSSPLANE_OVH_PROJECT_ID}" \
      --output json |
      jq -r --arg prefix "${prefix}-" '
        .[] | select((.description // "") | contains($prefix)) | .id | tostring'
  )

  kube delete providerconfig.ovh.m.edixos.io/provider-ovh \
    -n "${story_namespace}" --ignore-not-found --wait=false
  if [[ -z "$(kube get providerconfigusages.ovh.m.edixos.io \
    -n "${story_namespace}" -o name)" ]] &&
    kube get providerconfig.ovh.m.edixos.io/provider-ovh \
      -n "${story_namespace}" >/dev/null 2>&1; then
    # The isolated ProviderConfig may retain a stale usage count after all
    # managed resources and ProviderConfigUsage objects have disappeared.
    kube patch providerconfig.ovh.m.edixos.io/provider-ovh \
      -n "${story_namespace}" --type=merge \
      -p '{"metadata":{"finalizers":[]}}'
  fi
  kube delete providerconfig.kubernetes.m.crossplane.io/provider-kubernetes \
    -n "${story_namespace}" --ignore-not-found --wait=false
  kube delete namespace/"${story_namespace}" --wait=true --timeout=5m
  if ! kube get storages.pkg.internal -A -o json |
    jq -e 'any(.items[];
      .spec.crossplane.compositionSelector.matchLabels.provider == "ovh-capability-one")' \
      >/dev/null; then
    kube delete composition.apiextensions.crossplane.io/storage-ovh-capability-one \
      --ignore-not-found
  fi
  printf 'Removed OVHcloud story namespace %s.\n' "${story_namespace}"
}
