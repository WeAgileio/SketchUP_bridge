import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'client/bridge.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ClientTests(unittest.TestCase):
    def test_windows_path_forms_are_rejected_on_all_platforms(self):
        client = module.BridgeClient(Path.cwd())
        for path in ('../escape', '..\\escape', 'C:/escape', 'C:escape',
                     '/escape', '//server/share', 'results/id.json:stream',
                     'results/CON.json', 'results/LPT1', 'results/id.', 'a//b', 'a/./b'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                client.path(path)

    def test_utf8_bom_input_and_utf8_cli_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / '中文 空間'
            (root / 'inbox').mkdir(parents=True)
            source = root / 'request.json'
            request = {'request_id': 'utf8', 'arguments': {'name': '客廳 柜體'}}
            source.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8-sig')
            output = subprocess.run([sys.executable, str(Path(module.__file__)), '--root', str(root),
                                     'submit-file', str(source)], check=True, capture_output=True,
                                    env=dict(os.environ, PYTHONIOENCODING='ascii'))
            self.assertEqual(json.loads(output.stdout)['request'], request)
            queued = next((root / 'inbox').glob('*.json'))
            self.assertEqual(json.loads(queued.read_bytes()), request)

    @unittest.skipIf(os.name == 'nt', 'Windows junction is tested separately')
    def test_symbolic_link_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'link').symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                module.BridgeClient(root).path('link/session.json')

    @unittest.skipUnless(os.name == 'nt', 'Windows junction')
    def test_windows_junction_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'target').mkdir()
            link = root / 'junction'
            subprocess.run(['cmd', '/d', '/c', 'mklink', '/J', str(link), str(root / 'target')],
                           check=True, capture_output=True)
            try:
                with self.assertRaises(ValueError):
                    module.BridgeClient(root).path('junction/session.json')
            finally:
                link.rmdir()

    def test_read_closes_handle_before_atomic_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path = root / 'session.json'
            path.write_bytes(b'{"value":1}')
            self.assertEqual(module.BridgeClient(root).read('session.json'), {'value': 1})
            replacement = root / 'new.json'
            replacement.write_bytes(b'{"value":2}')
            os.replace(replacement, path)
            self.assertEqual(module.BridgeClient(root).read('session.json'), {'value': 2})

    def test_timeout_does_not_replay(self):
        with tempfile.TemporaryDirectory() as root:
            root = str(Path(root).resolve())
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
        with tempfile.TemporaryDirectory() as root:
            root = str(Path(root).resolve())
            client = module.BridgeClient(root)
            Path(root, 'results').mkdir()
            Path(root, 'rejections').mkdir()
            Path(root, 'results/same.json').write_text('{"status":"success"}')
            Path(root, 'rejections/receipt.json').write_text('{"status":"rejected"}')
            self.assertEqual(client.result('same', 'receipt')['status'], 'rejected')

    def test_paths_and_nonfinite_values(self):
        with tempfile.TemporaryDirectory() as root:
            root = str(Path(root).resolve())
            client = module.BridgeClient(root)
            with self.assertRaises(ValueError):
                client.path('../escape')
            with self.assertRaises(ValueError):
                client.submit_request({'request_id': 'x', 'number': float('nan')})


if __name__ == '__main__':
    unittest.main()
