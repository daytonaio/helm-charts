"""Execute the rendered registration hook offline with fake curl and kubectl."""

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / 'charts/daytona-region'
FIXTURE = CHART / 'tests/fixtures/baseline.values.yaml'
ENDPOINT = 'http://collector.example.internal:4318'

# These executables record requests instead of contacting a cluster or API. Only
# synthetic credentials are used, and unexpected operations fail the test.
FAKE_COMMAND = r'''
import base64
import json
import os
from pathlib import Path
import sys

import yaml

case = json.loads(Path(os.environ['MOCK_CASE']).read_text())
args = sys.argv[1:]
tool = Path(sys.argv[0]).name

def record(value):
    with open(os.environ['MOCK_CALLS'], 'a') as stream:
        stream.write(json.dumps(value) + '\n')

if tool == 'kubectl':
    if args[:2] == ['get', 'secret']:
        if not case.get('existing', False):
            sys.exit(1)
        if '-o' not in args:
            sys.exit(0)
        output = args[args.index('-o') + 1]
        data = {
            'id': case.get('region_id', 'custom-region_abcd'),
            'proxyApiKey': 'fixture-proxy-key',
        }
        if case.get('snapshot_credentials', True):
            data['snapshotManagerUsername'] = 'fixture-user'
            data['snapshotManagerPassword'] = 'fixture-password'
        encoded = {key: base64.b64encode(value.encode()).decode() for key, value in data.items()}
        if output == 'json':
            print(json.dumps({'data': encoded}))
        elif output == 'jsonpath={.data.id}':
            print(encoded['id'], end='')
        elif output == 'jsonpath={.data.snapshotManagerUsername}':
            print(encoded.get('snapshotManagerUsername', ''), end='')
        else:
            raise AssertionError(output)
    elif args[:2] == ['apply', '-f']:
        manifest = yaml.safe_load(Path(args[2]).read_text())
        record({'tool': tool, 'operation': 'apply', 'manifest': manifest})
    else:
        raise AssertionError(args)
elif tool == 'curl':
    method = args[args.index('-X') + 1]
    url = args[-1]
    payload = json.loads(args[args.index('-d') + 1]) if '-d' in args else None
    record({'tool': tool, 'method': method, 'url': url, 'payload': payload})
    if method == 'PATCH':
        if case.get('transport_error'):
            sys.exit(7)
        status = str(case.get('patch_status', 200))
        body = '' if status.startswith('2') else 'fixture API failure'
    elif method == 'POST' and url.endswith('/regenerate-snapshot-manager-credentials'):
        status = '200'
        body = json.dumps({'username': 'new-user', 'password': 'new-password'})
    elif method == 'POST' and url.endswith('/regions'):
        status = '201'
        body = json.dumps({'id': 'custom-region_abcd', 'proxyApiKey': 'fixture-proxy-key'})
    else:
        raise AssertionError((method, url))
    if '-o' in args:
        Path(args[args.index('-o') + 1]).write_text(body)
        print(status, end='')
    else:
        print(body)
else:
    raise AssertionError(tool)
'''


class RegistrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ['helm', 'jq', 'base64']:
            if not shutil.which(tool):
                raise RuntimeError(f'Required test dependency: {tool}')

    def render(self, overrides):
        with tempfile.TemporaryDirectory() as directory:
            values = Path(directory) / 'values.yaml'
            values.write_text(yaml.safe_dump(overrides))
            result = subprocess.run(
                ['helm', 'template', 'test-region', str(CHART), '--namespace', 'test-ns',
                 '-f', str(FIXTURE), '-f', str(values),
                 '--show-only', 'templates/region-registration-hook.yaml'],
                capture_output=True, text=True, timeout=30,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        return next(doc for doc in yaml.safe_load_all(result.stdout) if doc['kind'] == 'Job')

    def invoke(self, *, managed=False, endpoint='', case=None, snapshot=True):
        job = self.render({
            'registration': {'manageOtelEndpoint': managed},
            'otelEndpoint': endpoint,
            'services': {'snapshotManager': {'enabled': snapshot}},
        })
        container = job['spec']['template']['spec']['containers'][0]
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            binaries = temporary / 'bin'
            binaries.mkdir()
            for name in ['curl', 'kubectl']:
                command = binaries / name
                command.write_text(f'#!{sys.executable}\n' + FAKE_COMMAND)
                command.chmod(0o755)
            case_file = temporary / 'case.json'
            case_file.write_text(json.dumps(case or {}))
            calls_file = temporary / 'calls.jsonl'
            calls_file.touch()
            # Redirect only fixed temporary file paths; execute the rendered shell
            # unchanged otherwise, including its actual jq payload construction.
            script = temporary / 'hook.sh'
            script.write_text(container['command'][2].replace('/tmp/', f'{temporary}/'))
            environment = {
                'PATH': f'{binaries}{os.pathsep}{os.environ["PATH"]}',
                'MOCK_CASE': str(case_file), 'MOCK_CALLS': str(calls_file),
                'PYTHONDONTWRITEBYTECODE': '1',
            }
            for variable in container['env']:
                environment[variable['name']] = variable.get('value', 'fixture-api-key')
            result = subprocess.run(
                ['/bin/sh', str(script)], env=environment, cwd=directory,
                capture_output=True, text=True, timeout=15,
            )
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()]
        return result, calls

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def requests(self, calls):
        return [call for call in calls if call['tool'] == 'curl']

    def test_unmanaged_install_omits_endpoint(self):
        result, calls = self.invoke(endpoint=ENDPOINT)
        self.assert_success(result)
        request, = self.requests(calls)
        self.assertEqual(request['method'], 'POST')
        self.assertNotIn('otelEndpoint', request['payload'])

    def test_unmanaged_upgrade_does_not_change_region(self):
        result, calls = self.invoke(endpoint=ENDPOINT, case={'existing': True})
        self.assert_success(result)
        self.assertEqual(calls, [])

    def test_managed_install_sets_endpoint_with_or_without_snapshot_manager(self):
        for snapshot in [True, False]:
            with self.subTest(snapshot=snapshot):
                result, calls = self.invoke(managed=True, endpoint=ENDPOINT, snapshot=snapshot)
                self.assert_success(result)
                request, = self.requests(calls)
                self.assertEqual(request['payload']['otelEndpoint'], ENDPOINT)
                self.assertEqual('snapshotManagerUrl' in request['payload'], snapshot)

    def test_endpoint_is_json_data_not_shell_code(self):
        endpoint = 'https://collector.example.test/path/$(printf injected)"quoted'
        result, calls = self.invoke(managed=True, endpoint=endpoint)
        self.assert_success(result)
        self.assertEqual(self.requests(calls)[0]['payload']['otelEndpoint'], endpoint)

    def test_managed_empty_endpoint_is_null_on_install(self):
        result, calls = self.invoke(managed=True)
        self.assert_success(result)
        self.assertIsNone(self.requests(calls)[0]['payload']['otelEndpoint'])

    def test_managed_upgrade_sets_or_clears_only_endpoint(self):
        for endpoint in [ENDPOINT, '']:
            for status in [200, 204]:
                with self.subTest(endpoint=endpoint, status=status):
                    result, calls = self.invoke(
                        managed=True, endpoint=endpoint,
                        case={'existing': True, 'patch_status': status},
                    )
                    self.assert_success(result)
                    self.assertEqual(self.requests(calls), [{
                        'tool': 'curl', 'method': 'PATCH',
                        'url': 'https://api.daytona.example.com/api/regions/custom-region_abcd',
                        'payload': {'otelEndpoint': endpoint or None},
                    }])
                    self.assertEqual(len(calls), 1, 'Endpoint changes must not replace region credentials')

    def test_managed_upgrade_also_recovers_snapshot_credentials(self):
        result, calls = self.invoke(
            managed=True, endpoint=ENDPOINT,
            case={'existing': True, 'snapshot_credentials': False},
        )
        self.assert_success(result)
        self.assertEqual([call['method'] for call in self.requests(calls)], ['PATCH', 'POST'])
        applied, = [call['manifest'] for call in calls if call['tool'] == 'kubectl']
        data = {key: base64.b64decode(value).decode() for key, value in applied['data'].items()}
        self.assertEqual(data, {
            'id': 'custom-region_abcd', 'proxyApiKey': 'fixture-proxy-key',
            'snapshotManagerUsername': 'new-user', 'snapshotManagerPassword': 'new-password',
        })

    def test_unmanaged_upgrade_still_recovers_snapshot_credentials(self):
        result, calls = self.invoke(case={'existing': True, 'snapshot_credentials': False})
        self.assert_success(result)
        self.assertEqual([call['method'] for call in self.requests(calls)], ['POST'])

    def test_patch_failure_fails_hook_before_other_mutations(self):
        for failure in [{'patch_status': 403}, {'patch_status': 500}, {'transport_error': True}]:
            with self.subTest(failure=failure):
                result, calls = self.invoke(
                    managed=True, endpoint=ENDPOINT,
                    case={'existing': True, 'snapshot_credentials': False, **failure},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual([call['method'] for call in self.requests(calls)], ['PATCH'])
                self.assertEqual(len(calls), 1)

    def test_missing_region_id_fails_without_api_request(self):
        result, calls = self.invoke(
            managed=True, endpoint=ENDPOINT, case={'existing': True, 'region_id': ''},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
