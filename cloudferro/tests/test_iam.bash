#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/cloudferro/dependencies/iam.sh"
if "$script" destroy >/dev/null 2>&1; then
  printf 'CloudFerro IAM bootstrap accepted an unsupported destroy command.\n' >&2
  exit 1
fi
test_root=$(mktemp -d /tmp/provider-storage-cloudferro-test.XXXXXXXX)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin"

slot_one_project_id=0123456789abcdef0123456789abcdef
slot_two_project_id=fedcba9876543210fedcba9876543210
unmatched_project_id=00112233445566778899aabbccddeeff
domain_id=1234567890abcdef1234567890abcdef
bootstrap_user_id=abcdef0123456789abcdef0123456789
created_controller_user_id=778899aabbccddeeff00112233445566
member_role_id=8899aabbccddeeff0011223344556677
other_role_id=99aabbccddeeff001122334455667788
login_project_id=11223344556677889900aabbccddeeff
other_user_id=ffeeddccbbaa00998877665544332211
wrong_project_id=deadbeef00112233445566778899aabb

cat >"$test_root/bin/mock" <<'PY'
#!/usr/bin/env python3
import base64
import getpass
import json
import os
import pathlib
import re
import sys

state_dir = pathlib.Path(os.environ["TEST_STATE_DIR"])
slot_one_project_id = os.environ["TEST_SLOT_ONE_PROJECT_ID"]
slot_two_project_id = os.environ["TEST_SLOT_TWO_PROJECT_ID"]
domain_id = os.environ["TEST_DOMAIN_ID"]
bootstrap_user_id = os.environ["TEST_BOOTSTRAP_USER_ID"]
created_controller_user_id = os.environ["TEST_CREATED_CONTROLLER_USER_ID"]
member_role_id = os.environ["TEST_MEMBER_ROLE_ID"]
other_role_id = os.environ["TEST_OTHER_ROLE_ID"]
login_project_id = os.environ["TEST_LOGIN_PROJECT_ID"]
arguments = sys.argv[1:]
command = pathlib.Path(sys.argv[0]).name
with (state_dir / "calls").open("a") as log:
    log.write(f"{command} {' '.join(arguments)}\n")

def load(name, default):
    file = state_dir / name
    return json.loads(file.read_text()) if file.exists() else default

def save(name, value):
    (state_dir / name).write_text(json.dumps(value))

def emit(value):
    print(json.dumps(value))

if command == "openstack":
    words = [word for word in arguments if not word.startswith("--")]
    profile = arguments[arguments.index("--os-cloud") + 1] if "--os-cloud" in arguments else "admin"
    project_id = (arguments[arguments.index("--os-project-id") + 1]
                  if "--os-project-id" in arguments else os.environ.get("OS_PROJECT_ID"))
    if "--os-cloud" not in arguments and project_id != login_project_id:
        assert "OS_PROJECT_NAME" not in os.environ
    if profile == "admin":
        if "token" in words and "issue" in words:
            token = {"user_id": os.environ.get("TEST_ACTIVE_USER_ID", bootstrap_user_id)}
            if os.environ.get("TEST_TOKEN_SCOPE") == "domain" and not project_id:
                token["domain_id"] = domain_id
            else:
                token["project_id"] = project_id or login_project_id
            if "-c" in arguments:
                print(token[arguments[arguments.index("-c") + 1]])
            else:
                emit(token)
        elif "project" in words and "list" in words:
            assert "--my-projects" not in arguments
            if os.environ.get("TEST_DENY_PROJECT_LIST"):
                sys.exit(27)
            projects = load("projects.json", [])
            if "--long" in arguments:
                emit([{"ID": item["id"], "Name": item["name"],
                       "Domain ID": item["domain_id"], "Enabled": item["enabled"]}
                      for item in projects])
            else:
                emit([{"ID": item["id"], "Name": item["name"]} for item in projects])
        elif "project" in words and "show" in words:
            target = arguments[arguments.index("show") + 1]
            if target == login_project_id:
                if "-c" in arguments:
                    print(domain_id)
                else:
                    emit({"id": target, "domain_id": domain_id, "enabled": True})
            else:
                sys.exit(29)
        elif "project" in words and "create" in words:
            sys.exit(28)
        elif "user" in words and "create" in words:
            assert sys.stdin.isatty(), "OpenStack password prompt needs a terminal"
            first_password = getpass.getpass("User Password:")
            second_password = getpass.getpass("Repeat User Password:")
            assert first_password and first_password == second_password
            failure = os.environ.get("TEST_USER_CREATE_ERROR")
            if failure:
                errors = {
                    "forbidden": "Forbidden: identity:create_user (HTTP 403)",
                    "conflict": "Conflict: user name already exists (HTTP 409)",
                    "unauthorized": "Unauthorized: token expired (HTTP 401)",
                    "prompt": "No terminal detected attempting to read password",
                    "unknown": "OpenStack request failed",
                }
                print(errors[failure] + "; secret=fake-private-secret", file=sys.stderr)
                sys.exit(32)
            name = arguments[arguments.index("-f") - 1]
            assert "--project" not in arguments
            users = load("users.json", {})
            if any(item["name"] == name for item in users.values()):
                sys.exit(30)
            user_id = created_controller_user_id
            item = {"id": user_id, "name": name, "domain_id": domain_id,
                    "default_project_id": None,
                    "description": arguments[arguments.index("--description") + 1],
                    "enabled": True}
            users[user_id] = item
            save("users.json", users)
            emit(item)
        elif "user" in words and "show" in words:
            target = arguments[arguments.index("show") + 1]
            user = load("users.json", {}).get(target)
            if user is None:
                sys.exit(31)
            emit(user)
        elif "user" in words and "delete" in words:
            target = arguments[arguments.index("delete") + 1]
            users = load("users.json", {})
            user = users.pop(target)
            save("users.json", users)
        elif "role" in words and "show" in words:
            if os.environ.get("TEST_DENY_ROLE_LOOKUP"):
                sys.exit(27)
            emit({"id": member_role_id if "member" in words else other_role_id})
        elif "role" in words and "assignment" in words and "list" in words:
            role = arguments[arguments.index("--role") + 1]
            project = arguments[arguments.index("--project") + 1]
            emit([{"Role": role}] if role in load("roles.json", {}).get(project, []) else [])
        elif "role" in words and "add" in words:
            failure = os.environ.get("TEST_ROLE_ADD_ERROR")
            if failure:
                errors = {
                    "forbidden": "Forbidden: identity:create_grant (HTTP 403)",
                    "missing": "No Role found for member",
                    "unauthorized": "Unauthorized: token expired (HTTP 401)",
                    "unknown": "OpenStack request failed",
                }
                print(errors[failure] + "; secret=fake-private-secret", file=sys.stderr)
                sys.exit(33)
            roles = load("roles.json", {})
            project = arguments[arguments.index("--project") + 1]
            role = arguments[arguments.index("--project") + 2]
            roles.setdefault(project, [])
            if role not in roles[project]:
                roles[project].append(role)
            save("roles.json", roles)
        elif "role" in words and "remove" in words:
            roles = load("roles.json", {})
            project = arguments[arguments.index("--project") + 1]
            role = arguments[arguments.index("--project") + 2]
            roles[project] = [item for item in roles.get(project, []) if item != role]
            save("roles.json", roles)
        else:
            sys.exit(20)
    elif profile == "provider-storage-slot":
        cloud_file = pathlib.Path(os.environ["OS_CLIENT_CONFIG_FILE"])
        cloud = json.loads(cloud_file.read_text())["clouds"]["provider-storage-slot"]
        assert cloud["auth"]["password"]
        project_id = cloud["auth"]["project_id"]
        user_id = cloud["auth"]["user_id"]
        assert user_id in load("users.json", {})
        if "token" in words and "issue" in words:
            column = arguments[arguments.index("-c") + 1]
            print(os.environ["TEST_WRONG_PROJECT_ID"] if os.environ.get("TEST_WRONG_PROJECT") and column == "project_id"
                  else project_id if column == "project_id" else user_id)
        elif "container" in words and "list" in words:
            emit([])
        else:
            sys.exit(23)
    else:
        sys.exit(24)
elif command == "kubectl":
    if "get" in arguments:
        kind = arguments[arguments.index("get") + 1]
        name = arguments[arguments.index("get") + 2]
        if kind in ("namespace", "crd"):
            print(name)
        elif kind == "storages.pkg.internal":
            emit({"items": load("storages.json", [])})
        else:
            resources = load("resources.json", {})
            if kind == "providerconfig.openstack.m.crossplane.io":
                kind = "providerconfig"
            item = resources.get(f"{kind}/{name}")
            if item:
                emit(item)
    elif "create" in arguments and "secret" in arguments:
        name = arguments[arguments.index("generic") + 1]
        file = pathlib.Path(arguments[arguments.index("--from-file=config") + 1]) if "--from-file=config" in arguments else pathlib.Path(next(arg.split("=", 2)[2] for arg in arguments if arg.startswith("--from-file=config=")))
        emit({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": name},
              "data": {"config": base64.b64encode(file.read_bytes()).decode()}})
    elif "apply" in arguments:
        file = pathlib.Path(arguments[arguments.index("-f") + 1])
        content = file.read_text()
        if content.lstrip().startswith("{"):
            item = json.loads(content)
        else:
            match = re.search(r"^  name: (storage-cloudferro-[0-9]{4})$", content, re.M)
            assert match
            item = {"kind": "Composition", "metadata": {"name": match.group(1),
                    "labels": {"app.kubernetes.io/managed-by": "provider-storage-cloudferro-iam",
                               "provider": match.group(1).removeprefix("storage-")}}}
            assert "--server-side" in arguments
            assert "--force-conflicts" in arguments
        kind = item["kind"].lower()
        resources = load("resources.json", {})
        resources[f"{kind}/{item['metadata']['name']}"] = item
        save("resources.json", resources)
    elif "delete" in arguments:
        kind = arguments[arguments.index("delete") + 1]
        name = arguments[arguments.index("delete") + 2]
        if kind == "providerconfig.openstack.m.crossplane.io":
            kind = "providerconfig"
        resources = load("resources.json", {})
        resources.pop(f"{kind}/{name}", None)
        save("resources.json", resources)
    else:
        sys.exit(25)
else:
    sys.exit(26)
PY
chmod +x "$test_root/bin/mock"
ln -s mock "$test_root/bin/openstack"
ln -s mock "$test_root/bin/kubectl"

new_case() {
  case_dir=$(mktemp -d "$test_root/case.XXXXXXXX")
  mkdir -p "$case_dir/state"
  jq -n --arg id "$slot_one_project_id" --arg domain "$domain_id" \
    '[{id:$id,name:"team-a-0001",domain_id:$domain,enabled:true}]' \
    >"$case_dir/state/projects.json"
}

run_iam() {
  TEST_STATE_DIR="$case_dir/state" \
  TEST_SLOT_ONE_PROJECT_ID="$slot_one_project_id" \
  TEST_SLOT_TWO_PROJECT_ID="$slot_two_project_id" \
  TEST_DOMAIN_ID="$domain_id" \
  TEST_BOOTSTRAP_USER_ID="$bootstrap_user_id" \
  TEST_CREATED_CONTROLLER_USER_ID="$created_controller_user_id" \
  TEST_MEMBER_ROLE_ID="$member_role_id" \
  TEST_OTHER_ROLE_ID="$other_role_id" \
  TEST_LOGIN_PROJECT_ID="$login_project_id" \
  TEST_WRONG_PROJECT_ID="$wrong_project_id" \
  CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN="${TEST_PROJECT_PATTERN-}" \
  CROSSPLANE_CLOUDFERRO_DOMAIN_ID="$domain_id" \
  CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD=admin \
  CROSSPLANE_CLOUDFERRO_PROJECT_ROLE="${TEST_PROJECT_ROLE-}" \
  CROSSPLANE_CLOUDFERRO_AUTH_URL=https://keystone.example.test/v3 \
  CROSSPLANE_CLOUDFERRO_REGION=WAW3-2 \
  CROSSPLANE_CLOUDFERRO_S3_REGION=RegionOne \
  CROSSPLANE_CLOUDFERRO_S3_ENDPOINT=https://s3.example.test \
  CROSSPLANE_CLOUDFERRO_KUBE_CONTEXT=kind-provider-storage-it \
  CROSSPLANE_CLOUDFERRO_NAMESPACE=default \
  CROSSPLANE_CLOUDFERRO_CREDENTIALS_DIR="$case_dir/private" \
  PATH="$test_root/bin:$PATH" "$script" "$@"
}

run_current_iam() {
  local token_scope=${TEST_TOKEN_SCOPE:-project}
  local -a scope_environment
  if [[ $token_scope == domain ]]; then
    scope_environment=(OS_DOMAIN_ID="$domain_id")
  else
    scope_environment=(OS_PROJECT_ID="$login_project_id" OS_PROJECT_NAME=eoepca OS_PROJECT_DOMAIN_ID="$domain_id")
  fi
  env -u OS_DOMAIN_ID -u OS_PROJECT_ID -u OS_PROJECT_NAME -u OS_PROJECT_DOMAIN_ID \
  "${scope_environment[@]}" \
  TEST_STATE_DIR="$case_dir/state" \
  TEST_SLOT_ONE_PROJECT_ID="$slot_one_project_id" \
  TEST_SLOT_TWO_PROJECT_ID="$slot_two_project_id" \
  TEST_DOMAIN_ID="$domain_id" \
  TEST_BOOTSTRAP_USER_ID="$bootstrap_user_id" \
  TEST_CREATED_CONTROLLER_USER_ID="$created_controller_user_id" \
  TEST_MEMBER_ROLE_ID="$member_role_id" \
  TEST_OTHER_ROLE_ID="$other_role_id" \
  TEST_LOGIN_PROJECT_ID="$login_project_id" \
  TEST_WRONG_PROJECT_ID="$wrong_project_id" \
  TEST_TOKEN_SCOPE="$token_scope" \
  OS_AUTH_TYPE=v3token OS_TOKEN="${TEST_ACTIVE_TOKEN-fake-current-token}" \
  OS_AUTH_URL=https://keystone.example.test/v3 OS_REGION_NAME=WAW3-2 \
  CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN="${TEST_PROJECT_PATTERN-}" \
  CROSSPLANE_CLOUDFERRO_DOMAIN_ID="$domain_id" \
  CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD=current \
  CROSSPLANE_CLOUDFERRO_PROJECT_ROLE="${TEST_PROJECT_ROLE-}" \
  CROSSPLANE_CLOUDFERRO_AUTH_URL=https://keystone.example.test/v3 \
  CROSSPLANE_CLOUDFERRO_REGION=WAW3-2 \
  CROSSPLANE_CLOUDFERRO_S3_REGION=RegionOne \
  CROSSPLANE_CLOUDFERRO_S3_ENDPOINT=https://s3.example.test \
  CROSSPLANE_CLOUDFERRO_KUBE_CONTEXT=kind-provider-storage-it \
  CROSSPLANE_CLOUDFERRO_NAMESPACE=default \
  CROSSPLANE_CLOUDFERRO_CREDENTIALS_DIR="$case_dir/private" \
  PATH="$test_root/bin:$PATH" "$script" "$@"
}

new_case
run_iam status >"$case_dir/status.out"
grep -Fq "cloudferro-0001: project=$slot_one_project_id project_name=team-a-0001 controller_user_id=missing" "$case_dir/status.out"
TEST_DENY_ROLE_LOOKUP=1 run_iam status >"$case_dir/no-role-lookup.out"
grep -Fq "cloudferro-0001: project=$slot_one_project_id project_name=team-a-0001 controller_user_id=missing" "$case_dir/no-role-lookup.out"
! grep -Fq 'role show' "$case_dir/state/calls"
! grep -Fq 'role assignment list' "$case_dir/state/calls"
! grep -Fq 'user show' "$case_dir/state/calls"
! grep -Eq 'project create|role add|kubectl .* apply' "$case_dir/state/calls"
grep -Fq 'project list --long -f json' "$case_dir/state/calls"
! grep -Fq -- '--my-projects' "$case_dir/state/calls"
! grep -Fq 'project list --domain' "$case_dir/state/calls"
! grep -Fq "project show $slot_one_project_id" "$case_dir/state/calls"

for failure in forbidden conflict unauthorized prompt unknown; do
  new_case
  if TEST_USER_CREATE_ERROR="$failure" run_iam apply >"$case_dir/user-create-error.out" 2>&1; then
    printf 'CloudFerro IAM accepted a failed user creation.\n' >&2
    exit 1
  fi
  case $failure in
    forbidden) expected='identity:create_user permission' ;;
    conflict) expected='already exists in domain' ;;
    unauthorized) expected='Refresh the login and retry' ;;
    prompt) expected='could not read the password prompt' ;;
    unknown) expected='could not create the shared controller user' ;;
  esac
  grep -Fq "$expected" "$case_dir/user-create-error.out"
  ! grep -Fq 'fake-private-secret' "$case_dir/user-create-error.out"
  [[ ! -e "$case_dir/state/users.json" ]]
  [[ ! -e "$case_dir/private/controller.identity.json" ]]
  ! grep -Eq 'role add|kubectl .* apply' "$case_dir/state/calls"
done

new_case
run_iam apply >"$case_dir/apply.out"
grep -Fq 'controller verified, cluster slot published' "$case_dir/apply.out"
grep -Fq "role add --user $created_controller_user_id --project $slot_one_project_id member" "$case_dir/state/calls"
! grep -Eq 'role add .* admin$' "$case_dir/state/calls"
! grep -Fq 'role show' "$case_dir/state/calls"
! grep -Fq 'role assignment list' "$case_dir/state/calls"
[[ $(stat -c '%a' "$case_dir/private") == 700 ]]
[[ $(stat -c '%a' "$case_dir/private/controller.identity.json") == 600 ]]
jq -e '[.[] | .default_project_id] == [null]' "$case_dir/state/users.json" >/dev/null
jq -e '.password | type == "string" and length > 0' "$case_dir/private/controller.identity.json" >/dev/null
! grep -Fq 'fake-private-secret' "$case_dir/apply.out"
jq -e --arg project "$slot_one_project_id" --arg controller "$created_controller_user_id" '."providerconfig/cloudferro-0001".spec.credentials.secretRef.name == "cloudferro-provider-creds" and
       ."providerconfig/cloudferro-0001".spec.credentials.secretRef.key == "cloudferro-0001" and
       ."providerconfig/cloudferro-0001".metadata.annotations["storages.pkg.internal/project-name"] == "team-a-0001" and
       ."providerconfig/cloudferro-0001".metadata.annotations["storages.pkg.internal/project-id"] == $project and
       ."providerconfig/cloudferro-0001".metadata.annotations["storages.pkg.internal/controller-user-id"] == $controller and
       ."environmentconfig/storage-cloudferro-0001".data.storage.serviceName == $project and
       ."environmentconfig/storage-cloudferro-0001".data.storage.controllerUserId == $controller and
       ."environmentconfig/storage-cloudferro-0001".data.storage.region == "WAW3-2" and
       ."environmentconfig/storage-cloudferro-0001".data.storage.s3Region == "RegionOne" and
       ."composition/storage-cloudferro-0001".metadata.labels["app.kubernetes.io/managed-by"] == "provider-storage-cloudferro-iam"' \
  "$case_dir/state/resources.json" >/dev/null
jq -e --arg project "$slot_one_project_id" --arg controller "$created_controller_user_id" '
  ."secret/cloudferro-provider-creds".data["cloudferro-0001"] |
  @base64d | fromjson | .tenant_id == $project and
  .default_domain == "" and
  (has("user_domain_id") | not) and
  .user_id == $controller and
  (.password | type == "string" and length > 0)
' "$case_dir/state/resources.json" >/dev/null
run_iam apply >"$case_dir/reapply.out"
! grep -Fq 'project create' "$case_dir/state/calls"
[[ $(grep -c 'user create' "$case_dir/state/calls") == 1 ]]
! grep -Fq 'application credential create' "$case_dir/state/calls"
run_iam verify >"$case_dir/verify.out"
run_iam delete >"$case_dir/delete.out"
grep -Fq 'role assignments and managed slot resources deleted' "$case_dir/delete.out"
[[ -e "$case_dir/private/controller.identity.json" ]]
jq -e 'length == 1' "$case_dir/state/users.json" >/dev/null
jq -e --arg project "$slot_one_project_id" '.[$project] == []' "$case_dir/state/roles.json" >/dev/null
jq -e 'has("providerconfig/cloudferro-0001") | not' "$case_dir/state/resources.json" >/dev/null
jq -e 'has("secret/cloudferro-provider-creds") | not' "$case_dir/state/resources.json" >/dev/null
jq -e 'length == 1 and .[0].name == "team-a-0001"' "$case_dir/state/projects.json" >/dev/null
! grep -Fq 'project delete' "$case_dir/state/calls"
! grep -Fq 'user delete' "$case_dir/state/calls"
run_iam delete >"$case_dir/redelete.out"

new_case
TEST_PROJECT_ROLE=_member_ run_iam apply >"$case_dir/role-override.out"
grep -Fq "role add --user $created_controller_user_id --project $slot_one_project_id _member_" "$case_dir/state/calls"

for failure in forbidden missing unauthorized unknown; do
  new_case
  if TEST_ROLE_ADD_ERROR="$failure" run_iam apply >"$case_dir/role-error.out" 2>&1; then
    printf 'CloudFerro IAM accepted a failed role assignment.\n' >&2
    exit 1
  fi
  case $failure in
    forbidden) expected='identity:create_grant permission' ;;
    missing) expected='CROSSPLANE_CLOUDFERRO_PROJECT_ROLE' ;;
    unauthorized) expected='Refresh the login and retry' ;;
    unknown) expected='Could not assign project role member' ;;
  esac
  grep -Fq "$expected" "$case_dir/role-error.out"
  ! grep -Fq 'fake-private-secret' "$case_dir/role-error.out"
  ! grep -Eq 'kubectl .* apply' "$case_dir/state/calls"
done

new_case
jq -n --arg first "$slot_one_project_id" --arg second "$slot_two_project_id" \
  --arg unrelated "$unmatched_project_id" --arg domain "$domain_id" \
  '[{id:$first,name:"team-a-0001",domain_id:$domain,enabled:true},
    {id:$second,name:"team-b-0002",domain_id:$domain,enabled:true},
    {id:$unrelated,name:"billing",domain_id:$domain,enabled:true}]' \
  >"$case_dir/state/projects.json"
run_iam apply >"$case_dir/two-slots.out"
grep -Fq "cloudferro-0002: project=$slot_two_project_id controller verified, cluster slot published" "$case_dir/two-slots.out"
jq -e --arg project "$slot_two_project_id" '."providerconfig/cloudferro-0001" and ."providerconfig/cloudferro-0002" and
       ."providerconfig/cloudferro-0002".metadata.annotations["storages.pkg.internal/project-name"] == "team-b-0002" and
       ."providerconfig/cloudferro-0002".metadata.annotations["storages.pkg.internal/project-id"] == $project and
       ."environmentconfig/storage-cloudferro-0001" and ."environmentconfig/storage-cloudferro-0002" and
       ."composition/storage-cloudferro-0001" and ."composition/storage-cloudferro-0002"' \
  "$case_dir/state/resources.json" >/dev/null
jq -e --arg first "$slot_one_project_id" --arg second "$slot_two_project_id" '
  (."secret/cloudferro-provider-creds".data["cloudferro-0001"] | @base64d | fromjson | .tenant_id) == $first and
  (."secret/cloudferro-provider-creds".data["cloudferro-0002"] | @base64d | fromjson | .tenant_id) == $second and
  (."secret/cloudferro-provider-creds".data["cloudferro-0001"] | @base64d | fromjson | .default_domain) == "" and
  (."secret/cloudferro-provider-creds".data["cloudferro-0002"] | @base64d | fromjson | .default_domain) == ""
' "$case_dir/state/resources.json" >/dev/null
[[ $(grep -c 'user create' "$case_dir/state/calls") == 1 ]]
! grep -Fq "project show $unmatched_project_id" "$case_dir/state/calls"
! grep -Fq 'project create' "$case_dir/state/calls"
run_iam verify >"$case_dir/two-slots-verify.out"
printf '[{"metadata":{"namespace":"other","name":"in-use"},"spec":{"crossplane":{"compositionSelector":{"matchLabels":{"provider":"cloudferro-0001"}}}}}]\n' >"$case_dir/state/storages.json"
if run_iam delete >"$case_dir/in-use.out" 2>&1; then
  printf 'CloudFerro IAM deleted a slot used by Storage.\n' >&2
  exit 1
fi
grep -Fq 'Storage still selects cloudferro-0001' "$case_dir/in-use.out"
! grep -Fq 'kubectl .* delete' "$case_dir/state/calls"

new_case
jq -n --arg id "$slot_one_project_id" --arg domain "$domain_id" \
  '[{id:$id,name:"team-a-0001",domain_id:$domain,enabled:false}]' \
  >"$case_dir/state/projects.json"
if run_iam apply >"$case_dir/foreign.out" 2>&1; then
  printf 'CloudFerro IAM adopted a disabled project.\n' >&2
  exit 1
fi
grep -Fq 'is disabled or has no enabled state' "$case_dir/foreign.out"
! grep -Fq 'role add' "$case_dir/state/calls"

new_case
jq -n --arg first "$slot_one_project_id" --arg second "$slot_two_project_id" \
  --arg domain "$domain_id" --arg foreign "$unmatched_project_id" \
  '[{id:$first,name:"team-a-0001",domain_id:$domain,enabled:true},
    {id:$second,name:"team-b-0002",domain_id:$foreign,enabled:true}]' \
  >"$case_dir/state/projects.json"
run_iam status >"$case_dir/foreign-domain.out"
grep -Fq "cloudferro-0001: project=$slot_one_project_id" "$case_dir/foreign-domain.out"
! grep -Fq 'cloudferro-0002' "$case_dir/foreign-domain.out"
! grep -Fq "project show $slot_two_project_id" "$case_dir/state/calls"

new_case
printf '{"providerconfig/cloudferro-0001":{"metadata":{"labels":{"app.kubernetes.io/managed-by":"someone-else"}}}}\n' >"$case_dir/state/resources.json"
if run_iam apply >"$case_dir/foreign-pc.out" 2>&1; then
  printf 'CloudFerro IAM adopted an unrelated ProviderConfig.\n' >&2
  exit 1
fi
grep -Fq 'Refusing to adopt existing' "$case_dir/foreign-pc.out"
! grep -Fq 'project create' "$case_dir/state/calls"

new_case
jq -n --arg project "$slot_one_project_id" \
  '{"providerconfig/cloudferro-0001":{
     metadata:{labels:{"app.kubernetes.io/managed-by":"provider-storage-cloudferro-iam"},
               annotations:{"storages.pkg.internal/project-name":"wrong-0001",
                            "storages.pkg.internal/project-id":$project}},
     spec:{credentials:{source:"Secret",secretRef:{name:"cloudferro-0001-provider-creds",
                                                   namespace:"default",key:"config"}}}}}' \
  >"$case_dir/state/resources.json"
if run_iam apply >"$case_dir/wrong-binding.out" 2>&1; then
  printf 'CloudFerro IAM accepted a ProviderConfig for another project name.\n' >&2
  exit 1
fi
grep -Fq 'different project binding' "$case_dir/wrong-binding.out"
! grep -Eq 'role add|application credential create|kubectl .* apply' "$case_dir/state/calls"

new_case
TEST_WRONG_PROJECT=1 run_iam apply >"$case_dir/wrong-project.out" 2>&1 && {
  printf 'CloudFerro IAM published a credential for the wrong project.\n' >&2
  exit 1
}
grep -Fq 'scoped to a different project' "$case_dir/wrong-project.out"
! grep -Fq 'kubectl .* apply' "$case_dir/state/calls"

new_case
run_current_iam check-login >"$case_dir/login.out"
grep -Fq "user_id=$bootstrap_user_id project_id=$login_project_id" "$case_dir/login.out"
grep -Fq 'Project listing: available.' "$case_dir/login.out"
! grep -Fq 'fake-current-token' "$case_dir/login.out"
! grep -Eq 'project create|role add|application credential create|kubectl .* apply' "$case_dir/state/calls"
run_current_iam apply >"$case_dir/current-apply.out"
grep -Fq 'controller verified, cluster slot published' "$case_dir/current-apply.out"
! grep -Fq 'fake-current-token' "$case_dir/state/calls"
run_current_iam verify >"$case_dir/current-verify.out"

new_case
TEST_TOKEN_SCOPE=domain run_current_iam check-login >"$case_dir/domain-login.out"
grep -Fq "user_id=$bootstrap_user_id domain_id=$domain_id" "$case_dir/domain-login.out"
! grep -Fq 'project_id=' "$case_dir/domain-login.out"
grep -Fq 'Project listing: available.' "$case_dir/domain-login.out"
! grep -Fq 'fake-current-token' "$case_dir/domain-login.out"
TEST_TOKEN_SCOPE=domain run_current_iam status >"$case_dir/domain-status.out"
grep -Fq "cloudferro-0001: project=$slot_one_project_id" "$case_dir/domain-status.out"
TEST_TOKEN_SCOPE=domain run_current_iam apply >"$case_dir/domain-apply.out"
grep -Fq 'controller verified, cluster slot published' "$case_dir/domain-apply.out"
TEST_TOKEN_SCOPE=domain run_current_iam verify >"$case_dir/domain-verify.out"
! grep -Fq 'fake-current-token' "$case_dir/state/calls"

new_case
jq -n --arg first "$slot_one_project_id" --arg second "$slot_two_project_id" \
  --arg domain "$domain_id" \
  '[{id:$first,name:"team-a-0001",domain_id:$domain,enabled:true},
    {id:$second,name:"team-b-0002",domain_id:$domain,enabled:true}]' \
  >"$case_dir/state/projects.json"
TEST_PROJECT_PATTERN='^team-a-([0-9]{4})$' run_current_iam status >"$case_dir/pattern-status.out"
grep -Fq "cloudferro-0001: project=$slot_one_project_id" "$case_dir/pattern-status.out"
! grep -Fq 'cloudferro-0002' "$case_dir/pattern-status.out"
TEST_PROJECT_PATTERN='^team-a-([0-9]{4})$' run_current_iam apply >"$case_dir/pattern-apply.out"
TEST_PROJECT_PATTERN='^team-a-([0-9]{4})$' run_current_iam verify >"$case_dir/pattern-verify.out"
! grep -Fq "project show $slot_two_project_id" "$case_dir/state/calls"
! grep -Fq 'project list --domain' "$case_dir/state/calls"
! grep -Fq 'project create' "$case_dir/state/calls"

new_case
jq -n --arg first "$slot_one_project_id" --arg second "$slot_two_project_id" \
  --arg domain "$domain_id" \
  '[{id:$first,name:"team-a-0001",domain_id:$domain,enabled:true},
    {id:$second,name:"team-b-0001",domain_id:$domain,enabled:true}]' \
  >"$case_dir/state/projects.json"
if run_current_iam apply >"$case_dir/collision.out" 2>&1; then
  printf 'CloudFerro IAM accepted two projects for one slot.\n' >&2
  exit 1
fi
grep -Fq 'More than one visible project maps to cloudferro-0001' "$case_dir/collision.out"
! grep -Eq 'project create|role add|application credential create|kubectl .* apply' "$case_dir/state/calls"

new_case
TEST_DENY_PROJECT_LIST=1 run_current_iam check-login >"$case_dir/no-list.out"
grep -Fq 'Project listing: unavailable' "$case_dir/no-list.out"
if TEST_DENY_PROJECT_LIST=1 run_current_iam apply >"$case_dir/no-list-apply.out" 2>&1; then
  printf 'CloudFerro IAM applied without project listing.\n' >&2
  exit 1
fi
grep -Fq 'OpenStack project listing failed' "$case_dir/no-list-apply.out"
! grep -Eq 'role add|application credential create|kubectl .* apply' "$case_dir/state/calls"

new_case
if TEST_PROJECT_PATTERN='^team-a-[0-9]{4}$' run_iam apply >"$case_dir/no-capture.out" 2>&1; then
  printf 'CloudFerro IAM accepted a project pattern without a slot capture.\n' >&2
  exit 1
fi
grep -Fq 'must capture exactly four digits' "$case_dir/no-capture.out"
! grep -Eq 'role add|application credential create|kubectl .* apply' "$case_dir/state/calls"

new_case
if TEST_PROJECT_PATTERN='^other-([0-9]{4})$' run_iam apply >"$case_dir/no-match.out" 2>&1; then
  printf 'CloudFerro IAM silently applied with no matching projects.\n' >&2
  exit 1
fi
grep -Fq 'No visible projects' "$case_dir/no-match.out"
! grep -Fq "project show $slot_one_project_id" "$case_dir/state/calls"
TEST_PROJECT_PATTERN='^other-([0-9]{4})$' run_iam delete >"$case_dir/no-match-delete.out"
grep -Fq 'nothing to delete' "$case_dir/no-match-delete.out"

new_case
if TEST_ACTIVE_TOKEN= run_current_iam check-login >"$case_dir/no-token.out" 2>&1; then
  printf 'CloudFerro accepted a missing active token.\n' >&2
  exit 1
fi
grep -Fq 'Source an active v3token' "$case_dir/no-token.out"

new_case
TEST_ACTIVE_USER_ID="$other_user_id" run_current_iam apply >"$case_dir/other-bootstrap-user.out"
grep -Fq 'controller verified, cluster slot published' "$case_dir/other-bootstrap-user.out"
! grep -Fq 'project create' "$case_dir/state/calls"

printf 'CloudFerro IAM bootstrap mock tests passed.\n'
