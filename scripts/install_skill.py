#!/usr/bin/env python3
"""Install the bundled skill without replacing an existing skill."""
import argparse
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def install(skills_dir):
    source = ROOT / 'skills/sketchup-modeling'
    destination = Path(skills_dir).expanduser() / source.name
    if destination.exists() or destination.is_symlink():
        raise FileExistsError('Skill already exists; back it up or choose another directory: ' + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    shutil.copy2(ROOT / 'LICENSE', destination / 'LICENSE')
    return destination.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_root = Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex')
    parser.add_argument('--skills-dir', type=Path, default=default_root / 'skills')
    args = parser.parse_args()
    try:
        print('Installed: ' + str(install(args.skills_dir)))
    except OSError as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
