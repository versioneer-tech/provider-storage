#!/usr/bin/env python3
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Check standalone IAM commands with local credentials and simulated cloud CLIs."""

import base64
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


SOURCE = Path(__file__).resolve().parents[1] / 'scripts/bootstrap-iam.sh'
DOMAIN = 'a' * 32
PROJECT = 'b' * 32
USER = 'c' * 32


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='test-bootstrap-iam-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.script = self.root / 'bootstrap-iam.sh'
        shutil.copy2(SOURCE, self.script)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('bash', 'cat', 'jq', 'stat', 'dirname', 'basename', 'id',
                     'realpath', 'mktemp', 'chmod', 'mkdir', 'mv', 'rm', 'cmp',
                     'ln', 'sleep', 'grep', 'sort', 'wc', 'openssl', 'setsid', 'timeout'):
            location = shutil.which(name, path='/usr/bin:/bin:/usr/local/bin')
            if not location:
                self.fail(f'Required test tool is missing: {name}')
            (self.bin / name).symlink_to(location)
        self.config = self.root / 'config'
        self.config.mkdir(mode=0o700)
        self.env = {'PATH': str(self.bin), 'HOME': str(self.root),
                    'PROVIDER_STORAGE_CONFIG_DIR': str(self.config)}

    def cli(self, name, body):
        executable = self.bin / name
        executable.write_text('#!/usr/bin/python3\n' + body)
        executable.chmod(0o700)

    def run_script(self, backend, action, extra=None, success=True, input_text=None):
        result = subprocess.run([str(self.script), backend, *(action if isinstance(action, list) else [action])],
                                env=self.env | (extra or {}), cwd=self.root,
                                capture_output=True, text=True, input=input_text, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def configure(self, backend, extra=None):
        values = {
            'aws': {'CROSSPLANE_AWS_ACCOUNT_ID': '123456789012', 'AWS_REGION': 'eu-central-1',
                    'CROSSPLANE_AWS_AUTH_MODE': 'static-user'},
            'otc': {'CROSSPLANE_OTC_DOMAIN_ID': DOMAIN, 'CROSSPLANE_OTC_PROJECT_ID': PROJECT},
            'ovh': {'CROSSPLANE_OVH_PROJECT_ID': PROJECT, 'CROSSPLANE_OVH_STORAGE_REGION': 'DE'},
            'cloudferro': {'CROSSPLANE_CLOUDFERRO_DOMAIN_ID': DOMAIN,
                          'CROSSPLANE_CLOUDFERRO_AUTH_URL': 'https://keystone.example.test/v3',
                          'CROSSPLANE_CLOUDFERRO_REGION': 'RegionOne',
                          'CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD': 'test-admin'},
        }
        return self.run_script(backend, 'configure', values[backend] | (extra or {}),
                               input_text='\n' * 8)

    def credentials(self, backend, identity, projects=None):
        self.configure(backend)
        path = self.config / f'{backend}-creds.json'
        data = json.loads(path.read_text())
        data['identity'] = identity
        if projects is not None:
            data['projects'] = projects
        path.write_text(json.dumps(data))
        return path

    def test_render_preserves_provider_secret_formats(self):
        identities = {
            'aws': {'access_key_id': 'test-access', 'secret_access_key': 'test-secret'},
            'otc': {'access_key': 'test-access', 'secret_key': 'test-secret',
                    'auth_url': 'https://iam.eu-nl.otc.t-systems.com/v3', 'domain_name': 'test',
                    'domain_id': DOMAIN, 'tenant_id': PROJECT},
            'ovh': {'endpoint': 'ovh-eu', 'client_id': 'test-client', 'client_secret': 'test-secret'},
            'cloudferro': {'auth_url': 'https://keystone.example.test/v3',
                          'region': 'RegionOne', 'domain_id': DOMAIN, 'user_id': USER,
                          'user_name': 'provider-storage-controller', 'password': 'test-password'},
        }
        for backend, identity in identities.items():
            with self.subTest(backend=backend):
                projects = [PROJECT, 'd' * 32] if backend == 'cloudferro' else None
                path = self.credentials(backend, identity | {'account_identifier': DOMAIN}, projects)
                before = path.read_bytes()
                namespace = {f'CROSSPLANE_{backend.upper()}_NAMESPACE': 'test-bootstrap'}
                result = self.run_script(backend, 'render-secrets', namespace)
                documents = list(yaml.safe_load_all(result.stdout))
                self.assertEqual(len(documents), len(projects or [None]))
                for secret, project in zip(documents, projects or [None]):
                    self.assertEqual(secret['kind'], 'Secret')
                    self.assertEqual(secret['type'], 'Opaque')
                    self.assertEqual(secret['metadata']['namespace'], 'test-bootstrap')
                    name = f'cloudferro-project-{project}' if project else f'{backend}-provider-creds'
                    self.assertEqual(secret['metadata']['name'], name)
                    key = 'config' if project else 'credentials'
                    decoded = base64.b64decode(secret['data'][key]).decode()
                    if backend == 'aws':
                        self.assertEqual(decoded, '[default]\naws_access_key_id = test-access\n'
                                                 'aws_secret_access_key = test-secret')
                    elif backend == 'cloudferro':
                        self.assertEqual(json.loads(decoded), {
                            'auth_url': identity['auth_url'], 'region': 'RegionOne',
                            'user_id': USER, 'password': 'test-password',
                            'default_domain': '', 'tenant_id': project})
                    else:
                        self.assertEqual(json.loads(decoded), identity)
                status = self.run_script(backend, 'show')
                self.assertIn(f'file: {path}', status.stdout)
                if backend == 'ovh':
                    self.assertIn('client: test-client', status.stdout)
                    self.assertIn('endpoint: ovh-eu', status.stdout)
                self.assertNotIn('test-secret', status.stdout + status.stderr)
                self.assertNotIn('test-password', status.stdout + status.stderr)
                self.assertEqual(path.read_bytes(), before)

    def test_show_reports_missing_files_without_cloud_clis(self):
        for backend in ('aws', 'otc', 'ovh', 'cloudferro'):
            with self.subTest(backend=backend):
                result = self.run_script(backend, 'show')
                self.assertIn('(missing)', result.stdout)
                self.assertFalse((self.config / f'{backend}-creds.json').exists())

    def test_configure_is_local_and_required_before_cloud_operations(self):
        for backend, command in [('aws', 'aws'), ('otc', 'openstack'),
                                 ('ovh', 'ovhcloud'), ('cloudferro', 'openstack')]:
            with self.subTest(backend=backend):
                self.cli(command, 'raise SystemExit("Cloud API must not run")\n')
                for operation in ('apply', 'verify'):
                    result = self.run_script(backend, operation, success=False)
                    self.assertIn('Run configure first', result.stderr)
                self.configure(backend)
                path = self.config / f'{backend}-creds.json'
                data = json.loads(path.read_text())
                self.assertEqual(data['config']['backend'], backend)
                self.assertEqual(data['identity'], {})
                if backend == 'cloudferro':
                    self.assertEqual(data['projects'], [])
                    self.assertEqual(data['config']['project_pattern'], '^.+-[0-9]{4}$')
                self.assertIn(f'file: {path}', self.run_script(backend, 'show').stdout)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertIn('identity section has no credentials',
                              self.run_script(backend, 'render-secrets', success=False).stderr)
                key = 'storage_region' if backend == 'ovh' else 'region'
                del data['config'][key]
                path.write_text(json.dumps(data))
                for operation in ('apply', 'verify'):
                    result = self.run_script(backend, operation, success=False)
                    self.assertIn(f'config.{key} is required', result.stderr)
                    self.assertNotIn('Cloud API must not run', result.stderr)

    def test_configure_preserves_identity_and_rejects_target_changes(self):
        value = {'endpoint': 'ovh-eu', 'client_id': 'test-client', 'client_secret': 'test-secret'}
        path = self.credentials('ovh', value)
        self.configure('ovh')
        data = json.loads(path.read_text())
        self.assertEqual(data['identity'], value)
        self.assertEqual(data['config']['storage_region'], 'DE')
        before = path.read_bytes()
        result = self.run_script('ovh', 'configure', {'CROSSPLANE_OVH_STORAGE_REGION': 'GRA'},
                                 success=False, input_text='\n' * 8)
        self.assertIn('Cannot change storage_region', result.stderr)
        self.assertEqual(path.read_bytes(), before)
        self.run_script('ovh', 'configure', success=False, input_text='')
        self.assertEqual(path.read_bytes(), before)

    def test_aws_workload_identity_needs_no_controller_secret(self):
        self.configure('aws', {
            'CROSSPLANE_AWS_AUTH_MODE': 'assume-role',
            'CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN': 'arn:aws:iam::123456789012:role/test-workload'})
        path = self.config / 'aws-creds.json'
        self.assertEqual(json.loads(path.read_text())['identity'], {})
        result = self.run_script('aws', ['apply', '--rotate-credentials'], success=False)
        self.assertIn('before rotating', result.stderr)
        self.assertIn('identity section has no credentials',
                      self.run_script('aws', 'render-secrets', success=False).stderr)

    def test_file_override_precedes_common_directory(self):
        path = self.credentials('aws', {'access_key_id': 'test-key',
                                        'secret_access_key': 'test-secret'})
        result = self.run_script('aws', 'render-secrets', {
            'CROSSPLANE_AWS_CREDENTIALS_FILE': str(path),
            'PROVIDER_STORAGE_CONFIG_DIR': 'invalid-relative-directory'})
        self.assertEqual(yaml.safe_load(result.stdout)['metadata']['name'], 'aws-provider-creds')

    def test_unsafe_credentials_are_rejected(self):
        path = self.credentials('aws', {'access_key_id': 'test-key',
                                        'secret_access_key': 'test-secret'})
        path.chmod(0o644)
        self.assertIn('0600', self.run_script('aws', 'render-secrets', success=False).stderr)
        path.chmod(0o600)
        link = self.root / 'link.json'
        link.symlink_to(path)
        result = self.run_script('aws', 'render-secrets', {
            'CROSSPLANE_AWS_CREDENTIALS_FILE': str(link)}, success=False)
        self.assertIn('symbolic link', result.stderr)
        self.credentials('ovh', {'endpoint': 'ovh-eu', 'client_id': 'test-client',
                                 'client_secret': 'test-secret'})
        (self.config / '.git').mkdir()
        (self.config / '.git' / 'HEAD').touch()
        self.assertIn('Git repositories',
                      self.run_script('ovh', 'render-secrets', success=False).stderr)

    def test_rotation_requires_an_applied_supported_identity(self):
        for backend in ('aws', 'otc', 'cloudferro'):
            with self.subTest(backend=backend):
                self.configure(backend)
                result = self.run_script(backend, ['apply', '--rotate-credentials'], success=False)
                self.assertIn('before rotating', result.stderr)
        result = self.run_script('ovh', ['apply', '--rotate-credentials'], success=False)
        self.assertIn('rotation is manual', result.stderr)

    def test_saved_ovh_project_and_storage_region_reject_drift(self):
        self.cli('ovhcloud', 'raise SystemExit("Cloud CLI must not run on conflict")\n')
        self.configure('ovh')
        for name, value in [('CROSSPLANE_OVH_STORAGE_REGION', 'GRA'),
                            ('CROSSPLANE_OVH_PROJECT_ID', 'd' * 32),
                            ('CROSSPLANE_OVH_API_REGION', 'CA')]:
            result = self.run_script('ovh', 'apply', {name: value}, success=False)
            self.assertIn(f'{name} conflicts with the saved', result.stderr)
            self.assertNotIn('Cloud CLI must not run', result.stderr)

    def test_otc_verify_uses_the_controller_key_without_an_admin_login(self):
        self.credentials('otc', {
            'access_key': 'test-access', 'secret_key': 'test-secret',
            'auth_url': 'https://iam.eu-nl.otc.t-systems.com/v3', 'domain_name': 'test',
            'domain_id': DOMAIN, 'tenant_id': PROJECT})
        self.configure('otc')
        self.cli('curl', """
import json
from pathlib import Path
import sys
args = sys.argv[1:]
if args == ['--version']:
    print('curl 8.10.1')
    raise SystemExit(0)
assert args[-1] == 'https://obs.eu-nl.otc.t-systems.com/'
assert args[args.index('--aws-sigv4') + 1] == 'aws:amz:eu-nl:s3'
settings = Path(args[args.index('--config') + 1]).read_text()
assert json.loads(settings.split('=', 1)[1]) == 'test-access:test-secret'
Path(args[args.index('--output') + 1]).write_text('<ListAllMyBucketsResult/>')
print('200', end='')
""")
        result = self.run_script('otc', 'verify')
        self.assertIn('OK Credential authentication', result.stdout)
        self.assertIn('OK OBS bucket listing', result.stdout)
        self.assertIn(f'domain: {DOMAIN}', result.stdout)
        self.assertNotIn('test-secret', result.stdout + result.stderr)
        self.cli('curl', """
from pathlib import Path
import sys
args = sys.argv[1:]
if args == ['--version']:
    print('curl 8.10.1')
    raise SystemExit(0)
Path(args[args.index('--output') + 1]).write_text(
    '<Error><Code>InvalidRequest</Code><Message>test-secret</Message></Error>')
print('400', end='')
""")
        result = self.run_script('otc', 'verify', success=False)
        self.assertIn('HTTP 400 (InvalidRequest)', result.stderr)
        self.assertNotIn('test-secret', result.stdout + result.stderr)
        self.cli('curl', "print('curl 7.81.0')\n")
        result = self.run_script('otc', 'verify', success=False)
        self.assertIn('curl 7.87 or later', result.stderr)

    def test_aws_apply_reuses_credentials_and_recovers_rotation(self):
        self.cli('aws', f'''
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
state = Path('{self.root}')
query = args[args.index('--query') + 1] if '--query' in args else ''
assert args[args.index('--region') + 1] == 'eu-central-1'
key_file = state / 'keys.json'
keys = json.loads(key_file.read_text()) if key_file.exists() else []
role = 'arn:aws:iam::123456789012:role/provider-storage/crossplane'
user = 'arn:aws:iam::123456789012:user/provider-storage/controller/crossplane'
if args[:2] == ['sts', 'get-caller-identity']:
    if query:
        print('123456789012' if query == 'Account' else user)
    else:
        assert not os.getenv('AWS_PROFILE')
        arn = 'arn:aws:sts::123456789012:assumed-role/crossplane/provider-storage-verify' if os.getenv('AWS_SESSION_TOKEN') else user
        print(json.dumps({{'Account': '123456789012', 'Arn': arn}}))
elif args[:2] == ['sts', 'assume-role']:
    assert os.getenv('AWS_ACCESS_KEY_ID') in keys
    print(json.dumps({{'Credentials': {{'AccessKeyId':'test-session-key','SecretAccessKey':'test-session-secret','SessionToken':'test-session-token'}}}}))
elif args[:2] == ['s3api', 'list-buckets']:
    assert os.getenv('AWS_SESSION_TOKEN') == 'test-session-token'
    if (state / 'fail-verify').exists():
        raise SystemExit(1)
    print('{{}}')
elif args[:2] in (['iam', 'get-role'], ['iam', 'get-user']):
    kind = args[1][4:]
    if not (state / kind).exists():
        raise SystemExit(1)
    print(role if kind == 'role' else user)
elif args[:2] in (['iam', 'create-role'], ['iam', 'create-user']):
    (state / args[1][7:]).touch()
elif args[1] in ['list-role-tags', 'list-user-tags']:
    print('provider-storage' if "project" in query else
          'aws-123456789012' if 'resource-prefix' in query else
          'runtime-controller' if args[1] == 'list-role-tags' else 'static-controller-source')
elif args[1] == 'list-access-keys':
    print('\\t'.join(keys))
elif args[1] == 'create-access-key':
    sequence_file = state / 'key-sequence'
    sequence = int(sequence_file.read_text()) + 1 if sequence_file.exists() else 1
    sequence_file.write_text(str(sequence))
    access = 'TESTACCESSKEY%02d' % sequence
    keys.append(access)
    key_file.write_text(json.dumps(keys))
    if query:
        print(access + '\\ttest-secret-key')
    else:
        print(json.dumps({{'AccessKey': {{'AccessKeyId':access,'SecretAccessKey':'test-rotated-secret'}}}}))
elif args[1] == 'delete-access-key':
    assert not (state / 'fail-verify').exists(), 'Old key retired before replacement verification'
    keys.remove(args[args.index('--access-key-id') + 1])
    key_file.write_text(json.dumps(keys))
elif args[1] in ['put-role-policy', 'put-user-policy', 'update-assume-role-policy']:
    option = '--policy-document' if '--policy-document' in args else '--assume-role-policy-document'
    policy = json.loads(Path(args[args.index(option) + 1].removeprefix('file://')).read_text())
    assert '__' not in json.dumps(policy)
    if args[1] == 'put-role-policy':
        statements = {{item['Sid']: item for item in policy['Statement']}}
        assert statements['ProtectControllerUser']['Effect'] == 'Deny'
        assert statements['ProtectControllerUser']['Resource'] == user
        assert statements['ManagePrefixedBuckets']['Resource'] == [
            'arn:aws:s3:::aws-123456789012-*', 'arn:aws:s3:::aws-123456789012-*/*']
        assert statements['ManageUsersAndAccessKeys']['Resource'] == 'arn:aws:iam::123456789012:user/provider-storage/managed/*'
        assert statements['ManagePolicies']['Resource'] == 'arn:aws:iam::123456789012:policy/provider-storage/managed/*'
    elif args[1] == 'put-user-policy':
        assert policy['Statement'] == [{{'Sid': 'AssumeProviderStorageRuntimeRole',
            'Effect': 'Allow', 'Action': 'sts:AssumeRole', 'Resource': role}}]
elif args[1] not in ['tag-user', 'tag-role', 'get-role-policy', 'get-user-policy']:
    raise SystemExit('Unexpected AWS request')
''')
        self.configure('aws')
        result = self.run_script('aws', 'apply')
        path = self.config / 'aws-creds.json'
        data = json.loads(path.read_text())
        self.assertEqual(data['config']['region'], 'eu-central-1')
        self.assertIn('/controller/crossplane', data['identity']['controller_identity'])
        second = self.run_script('aws', 'apply')
        self.assertEqual(json.loads(path.read_text()), data)
        self.assertIn('AWS controller is ready.', second.stdout)
        self.assertNotIn('test-secret-key', result.stdout + result.stderr + second.stdout + second.stderr)
        self.run_script('aws', 'verify')
        self.run_script('aws', 'render-secrets')
        failure = self.root / 'fail-verify'
        failure.touch()
        failed = self.run_script('aws', ['apply', '--rotate-credentials'], success=False)
        self.assertIn('Replacement verification failed', failed.stderr)
        pending = json.loads(path.read_text())
        self.assertEqual(pending['rotation']['previous_identity'], data['identity'])
        self.assertEqual(len(json.loads((self.root / 'keys.json').read_text())), 2)
        self.assertNotIn('test-rotated-secret', failed.stdout + failed.stderr)
        self.assertIn('finish the pending rotation',
                      self.run_script('aws', 'render-secrets', success=False).stderr)
        failure.unlink()
        self.run_script('aws', 'apply')
        resumed = json.loads(path.read_text())
        self.assertEqual(resumed['config'], data['config'])
        self.assertEqual(resumed['identity'], pending['identity'])
        self.assertNotEqual(resumed['identity']['access_key_id'], data['identity']['access_key_id'])
        self.assertNotIn('rotation', resumed)
        self.assertEqual(json.loads((self.root / 'keys.json').read_text()),
                         [resumed['identity']['access_key_id']])
        self.assertEqual((self.root / 'key-sequence').read_text(), '2')
        self.run_script('aws', 'verify')
        self.run_script('aws', 'render-secrets')
        self.run_script('aws', ['apply', '--rotate-credentials'])
        rotated = json.loads(path.read_text())
        self.assertNotIn('rotation', rotated)
        self.assertNotEqual(rotated['identity']['access_key_id'], resumed['identity']['access_key_id'])
        self.assertEqual(json.loads((self.root / 'keys.json').read_text()),
                         [rotated['identity']['access_key_id']])

    def test_ovh_verify_uses_the_service_account_without_an_admin_login(self):
        self.credentials('ovh', {'endpoint': 'ovh-eu', 'client_id': 'test-client',
                                 'client_secret': 'test-secret'})
        self.configure('ovh')
        self.cli('ovhcloud', f"""
import json
import os
import sys
args = sys.argv[1:]
assert os.environ['OVH_CLIENT_ID'] == 'test-client'
assert os.environ['OVH_CLIENT_SECRET'] == 'test-secret'
assert os.environ['HOME'] != '{self.root}'
if args[:3] == ['cloud', 'project', 'get']:
    assert args[3] == '{PROJECT}'
    print(json.dumps({{'id': '{PROJECT}'}}))
elif args[:3] == ['cloud', 'user', 'list']:
    assert args[args.index('--cloud-project') + 1] == '{PROJECT}'
    print('[]')
else:
    raise SystemExit('Unexpected controller request')
""")
        result = self.run_script('ovh', 'verify')
        self.assertIn('OK Credential authentication', result.stdout)
        self.assertIn(f'project: {PROJECT}', result.stdout)
        self.assertIn('OK Project scope', result.stdout)
        self.assertIn('OK Project user listing', result.stdout)
        self.assertNotIn('test-secret', result.stdout + result.stderr)

    def test_cloudferro_apply_reuses_identity_and_saves_project_context(self):
        self.cli('openstack', f'''
import getpass
import os
import json
from pathlib import Path
import sys
args = sys.argv[1:]
if 'token' in args:
    if 'value' in args:
        print('test-token')
    elif '--os-cloud' in args and args[args.index('--os-cloud') + 1] == 'provider-storage-project':
        source = json.loads(Path(os.environ['OS_CLIENT_CONFIG_FILE']).read_text())
        assert source['clouds']['provider-storage-project']['auth']['password'] == Path('{self.root}/cloud-password').read_text()
        print(json.dumps({{'user_id': '{USER}', 'project_id': '{PROJECT}'}}))
    else:
        print(json.dumps({{'user_id': '{USER}', 'domain_id': '{DOMAIN}'}}))
elif 'project' in args and 'list' in args:
    print(json.dumps([{{'ID': '{PROJECT}', 'Name': 'test-1001', 'Domain ID': '{DOMAIN}', 'Enabled': True}}]))
elif 'project' in args and 'show' in args:
    print(json.dumps({{'id': '{PROJECT}', 'name': 'test-1001', 'domain_id': '{DOMAIN}', 'enabled': True}}))
elif 'user' in args and 'list' in args:
    print('[]')
elif 'user' in args and 'create' in args:
    password = getpass.getpass('User Password:')
    assert password == getpass.getpass('User Password:') and len(password) == 64
    marker = Path('{self.root}/created')
    assert not marker.exists(), 'Controller must not be recreated'
    marker.touch()
    Path('{self.root}/cloud-password').write_text(password)
    print(json.dumps({{'id': '{USER}'}}))
elif 'user' in args and 'set' in args:
    password = getpass.getpass('User Password:')
    assert password == getpass.getpass('User Password:') and len(password) == 64
    assert args[-1] == '{USER}'
    Path('{self.root}/password-updated').touch()
    Path('{self.root}/cloud-password').write_text(password)
    history = Path('{self.root}/password-history')
    with history.open('a') as stream:
        stream.write(password + '\\n')
elif 'role' in args or 'container' in args:
    if ('container' in args and Path('{self.root}/fail-verify').exists()
            and Path('{self.root}/password-updated').exists()):
        raise SystemExit(1)
    print('[]')
else:
    raise SystemExit('Unexpected request')
''')
        self.configure('cloudferro')
        first = self.run_script('cloudferro', 'apply')
        path = self.config / 'cloudferro-creds.json'
        data = json.loads(path.read_text())
        self.assertEqual(data['projects'], [PROJECT])
        self.assertEqual(data['config']['region'], 'RegionOne')
        self.assertEqual(data['identity']['user_id'], USER)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        second = self.run_script('cloudferro', 'apply')
        self.assertEqual(json.loads(path.read_text()), data)
        self.assertNotIn(data['identity']['password'], first.stdout + first.stderr + second.stdout + second.stderr)
        self.run_script('cloudferro', 'verify')
        failure = self.root / 'fail-verify'
        failure.touch()
        failed = self.run_script('cloudferro', ['apply', '--rotate-credentials'], success=False)
        self.assertIn('Replacement verification failed', failed.stderr)
        interrupted = json.loads(path.read_text())
        self.assertIn('rotation', interrupted)
        self.assertEqual(interrupted['identity']['password'], (self.root / 'cloud-password').read_text())
        password_history = (self.root / 'password-history').read_text()
        # Simulate interruption after the cloud update but before local promotion.
        pending = json.loads(path.read_text())
        pending['identity'] = pending['rotation']['previous_identity']
        path.write_text(json.dumps(pending))
        self.assertIn('finish the pending rotation',
                      self.run_script('cloudferro', 'render-secrets', success=False).stderr)
        failure.unlink()
        self.run_script('cloudferro', 'apply')
        resumed = json.loads(path.read_text())
        self.assertNotIn('rotation', resumed)
        self.assertEqual(resumed['identity'], interrupted['identity'])
        self.assertNotEqual(resumed['identity']['password'], data['identity']['password'])
        self.assertEqual(resumed['projects'], data['projects'])
        self.assertEqual(resumed['config'], data['config'])
        self.assertEqual((self.root / 'password-history').read_text(), password_history)
        self.run_script('cloudferro', 'verify')
        rendered = self.run_script('cloudferro', 'render-secrets')
        self.assertIn('Secret', rendered.stdout)
        self.run_script('cloudferro', ['apply', '--rotate-credentials'])
        rotated = json.loads(path.read_text())
        self.assertNotIn('rotation', rotated)
        self.assertNotEqual(rotated['identity']['password'], resumed['identity']['password'])
        self.assertEqual(rotated['identity']['password'], (self.root / 'cloud-password').read_text())

    def test_cloudferro_project_selection_follows_the_pattern(self):
        identity = {'auth_url': 'https://keystone.example.test/v3', 'region': 'RegionOne',
                    'domain_id': DOMAIN, 'user_id': USER,
                    'user_name': 'provider-storage-controller', 'password': 'test-password'}
        path = self.credentials('cloudferro', identity, [PROJECT])
        project_name = self.root / 'project-name'
        project_name.write_text('test-1001')
        listed = self.root / 'containers-listed'
        self.cli('openstack', f'''
import json
from pathlib import Path
import sys
args = sys.argv[1:]
assert args[:2] == ['--os-cloud', 'provider-storage-project']
if 'token' in args:
    print(json.dumps({{'user_id': '{USER}', 'project_id': '{PROJECT}'}}))
elif 'project' in args:
    print(json.dumps({{'id': '{PROJECT}', 'name': Path('{project_name}').read_text(),
                      'domain_id': '{DOMAIN}', 'enabled': True}}))
elif 'container' in args:
    Path('{listed}').touch()
    print('[]')
else:
    raise SystemExit('Unexpected cloud request')
''')
        result = self.run_script('cloudferro', 'verify')
        self.assertIn(f'project: test-1001 ({PROJECT})', result.stdout)
        self.assertIn('OK Project scope and pattern', result.stdout)
        listed.unlink()
        project_name.write_text('outside-selection')
        result = self.run_script('cloudferro', 'verify', success=False)
        self.assertIn('outside-selection', result.stderr)
        self.assertIn('does not match', result.stderr)
        self.assertFalse(listed.exists())
        self.configure('cloudferro', {'CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN': '^slot-[0-9]{4}$'})
        data = json.loads(path.read_text())
        self.assertEqual(data['identity'], identity)
        self.assertEqual(data['projects'], [])
        for action in ('verify', 'render-secrets'):
            result = self.run_script('cloudferro', action, success=False)
            self.assertIn('Run apply to select projects', result.stderr)


if __name__ == '__main__':
    unittest.main()
