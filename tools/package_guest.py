#!/usr/bin/env python3
"""Stage a separate original executable data module; verify SHA-256.

No thinning, Mach-O edits, signature removal, or re-signing of the guest.
The destination must be outside an application bundle. Import this module after
installing the signed runtime; no game code is sealed into the host signature.
"""
import argparse
import hashlib
import json
from pathlib import Path
import os
import shutil
import tempfile


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            checksum.update(block)
    return checksum.hexdigest()


def package(source, destination):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    if any(p.suffix.lower() in {'.app', '.framework', '.appex'} for p in (destination, *destination.parents)):
        raise ValueError('guest modules must be outside signed application bundles')
    if source == destination or destination in source.parents:
        raise ValueError('source must be outside the generated guest resource directory')
    destination.mkdir(parents=True, exist_ok=True)
    original_hash = digest(source)
    with tempfile.TemporaryDirectory(dir=destination) as tmp:
        staged = Path(tmp) / 'OriginalExecutable.bin'
        shutil.copyfile(source, staged)
        if digest(staged) != original_hash or digest(source) != original_hash:
            raise RuntimeError('source changed during packaging, or copy verification failed')
        os.chmod(staged, 0o644)
        manifest = Path(tmp) / 'manifest.json'
        manifest.write_text(json.dumps({'format': 2, 'runtime': 'data-module',
            'source_name': source.name, 'sha256': original_hash,
            'size': staged.stat().st_size, 'modified': False}, indent=2) + '\n')
        os.replace(staged, destination / staged.name)
        os.replace(manifest, destination / manifest.name)
    print(f'Original guest copied unchanged: SHA-256 {original_hash}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    package(args.source, args.destination)
