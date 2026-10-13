#!/usr/bin/env python3
"""Build reproducible RBZ and skill ZIP archives from selected project files."""
import argparse
import hashlib
from pathlib import Path
import re
from zipfile import ZipFile, ZIP_DEFLATED, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
SKILL_FILES = (
    'SKILL.md', 'agents/openai.yaml', 'scripts/bridge.py',
    'references/actions.md', 'references/ruby.md',
)


def write_archive(output, entries):
    with ZipFile(output, 'w', compression=ZIP_DEFLATED) as archive:
        for name, content in sorted(entries.items()):
            entry = ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, content, compress_type=ZIP_DEFLATED)
    with ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError('Corrupt archive: ' + str(output))


def build(output_dir):
    registration = ROOT / 'extension/codex_sketchup_bridge.rb'
    version = re.search(r"VERSION = '([0-9]+\.[0-9]+\.[0-9]+)'", registration.read_text()).group(1)
    skill = ROOT / 'skills/sketchup-modeling'
    if (ROOT / 'client/bridge.py').read_bytes() != (skill / 'scripts/bridge.py').read_bytes():
        raise ValueError('Skill client differs from client/bridge.py; synchronize it before packaging')
    license_bytes = (ROOT / 'LICENSE').read_bytes()
    rbz_entries = {p.relative_to(ROOT / 'extension').as_posix(): p.read_bytes()
                   for p in (ROOT / 'extension').rglob('*.rb')}
    rbz_entries['codex_sketchup_bridge/LICENSE'] = license_bytes
    skill_entries = {'sketchup-modeling/' + name: (skill / name).read_bytes() for name in SKILL_FILES}
    skill_entries['sketchup-modeling/LICENSE'] = license_bytes
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    outputs = [output_dir / ('codex-sketchup-bridge-' + version + '.rbz'),
               output_dir / ('sketchup-modeling-' + version + '.zip')]
    write_archive(outputs[0], rbz_entries)
    write_archive(outputs[1], skill_entries)
    (output_dir / 'SHA256SUMS').write_text(''.join(
        hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in outputs))
    return outputs


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    for path in build(parser.parse_args().output):
        print(path)
