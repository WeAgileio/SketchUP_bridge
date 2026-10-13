import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DistributionTests(unittest.TestCase):
    def test_archives_reproduce_source_and_checksums(self):
        package = load_script('package')
        with tempfile.TemporaryDirectory() as directory:
            paths = package.build(directory)
            before = [p.read_bytes() for p in paths]
            with ZipFile(paths[0]) as archive:
                expected = {p.relative_to(ROOT / 'extension').as_posix()
                            for p in (ROOT / 'extension').rglob('*.rb')}
                self.assertEqual(set(archive.namelist()), expected | {'codex_sketchup_bridge/LICENSE'})
                for name in expected:
                    self.assertEqual(archive.read(name), (ROOT / 'extension' / name).read_bytes())
            with ZipFile(paths[1]) as archive:
                self.assertEqual(len(archive.namelist()), len(package.SKILL_FILES) + 1)
                self.assertEqual(archive.read('sketchup-modeling/scripts/bridge.py'),
                                 (ROOT / 'client/bridge.py').read_bytes())
                self.assertEqual(archive.read('sketchup-modeling/LICENSE'), (ROOT / 'LICENSE').read_bytes())
            for line in (Path(directory) / 'SHA256SUMS').read_text().splitlines():
                digest, name = line.split('  ', 1)
                self.assertEqual(digest, hashlib.sha256((Path(directory) / name).read_bytes()).hexdigest())
            package.build(directory)
            self.assertEqual(before, [p.read_bytes() for p in paths])

    def test_install_is_self_contained_and_preserves_existing_skill(self):
        installer = load_script('install_skill')
        with tempfile.TemporaryDirectory() as directory:
            destination = installer.install(directory)
            self.assertTrue((destination / 'SKILL.md').is_file())
            self.assertEqual((destination / 'scripts/bridge.py').read_bytes(),
                             (ROOT / 'client/bridge.py').read_bytes())
            (destination / 'SKILL.md').write_text('existing user changes')
            with self.assertRaises(FileExistsError):
                installer.install(directory)
            self.assertEqual((destination / 'SKILL.md').read_text(), 'existing user changes')


if __name__ == '__main__':
    unittest.main()
