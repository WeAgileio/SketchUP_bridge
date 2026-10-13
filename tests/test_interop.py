"""Exercise the actual Ruby transport and Python client in separate processes."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bridge_interop', ROOT / 'client/bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class InteropTests(unittest.TestCase):
    def test_unicode_requests_deduplication_and_concurrent_heartbeat(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / '中文 佇列'
            process = subprocess.Popen(['ruby', str(ROOT / 'tests/fixtures/transport_server.rb'), str(root)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            client = bridge.BridgeClient(root)
            try:
                deadline = time.monotonic() + 10
                while not (root / 'session.json').exists():
                    if process.poll() is not None:
                        out, err = process.communicate()
                        self.fail((out + err).decode('utf-8', errors='replace'))
                    if time.monotonic() >= deadline:
                        self.fail('Ruby transport did not start')
                    time.sleep(0.02)
                state = client.state()
                for number in range(10):
                    args = {'name': '客廳 櫃體', 'iteration': number, 'lines': 'a\nb'}
                    submitted = client.submit('echo', args, model_token=state['model_token'],
                                              expected_revision=state['revision'])
                    response = client.wait(submitted['request_id'], submitted['receipt'], timeout=5)
                    self.assertEqual(response['status'], 'success', response)
                    self.assertEqual(response['data']['echo'], args)
                    state = response
                replay = client.submit_request(submitted['request'])
                response = client.wait(replay['request_id'], replay['receipt'], timeout=5)
                self.assertEqual(response['data']['executions'], 10)
                # Windows readers without FILE_SHARE_DELETE break Ruby's next rename.
                with bridge.open_binary_read(root / 'session.json') as held_reader:
                    previous = json.loads(held_reader.read())['heartbeat_at']
                    deadline = time.monotonic() + 5
                    while client.state()['heartbeat_at'] == previous and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertNotEqual(client.state()['heartbeat_at'], previous)
                self.assertIsNone(process.poll(), 'Ruby transport exited during heartbeat replacement')
            finally:
                if root.exists():
                    (root / 'test-stop').touch()
                try:
                    out, err = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    out, err = process.communicate()
                self.assertEqual(process.returncode, 0, (out + err).decode('utf-8', errors='replace'))


if __name__ == '__main__':
    unittest.main()
