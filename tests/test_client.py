import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'client/bridge.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ClientTests(unittest.TestCase):
    def test_timeout_does_not_replay(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as root:
            client = module.BridgeClient(root)
            for d in ('inbox', 'results', 'processing', 'rejections'):
                Path(root, d).mkdir()
            request = {'request_id': 'same', 'arguments': {}}
            submitted = client.submit_request(request)
            with self.assertRaises(TimeoutError):
                client.wait('same', submitted['receipt'], timeout=0)
            self.assertEqual(len(list(Path(root, 'inbox').iterdir())), 1)
            Path(root, 'results/same.json').write_text(json.dumps({'status': 'success'}))
            self.assertIsNone(client.result('same', submitted['receipt']))
            Path(root, 'inbox', submitted['receipt'] + '.json').unlink()
            self.assertEqual(client.wait('same', submitted['receipt'], 0)['status'], 'success')

    def test_conflict_receipt_wins(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as root:
            client = module.BridgeClient(root)
            Path(root, 'results').mkdir()
            Path(root, 'rejections').mkdir()
            Path(root, 'results/same.json').write_text('{"status":"success"}')
            Path(root, 'rejections/receipt.json').write_text('{"status":"rejected"}')
            self.assertEqual(client.result('same', 'receipt')['status'], 'rejected')

    def test_paths_and_nonfinite_values(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as root:
            client = module.BridgeClient(root)
            with self.assertRaises(ValueError):
                client.path('../escape')
            Path(root, 'escape').symlink_to('/private/tmp')
            with self.assertRaises(ValueError):
                client.path('escape/file')
            with self.assertRaises(ValueError):
                client.submit_request({'request_id': 'x', 'number': float('nan')})


if __name__ == '__main__':
    unittest.main()
