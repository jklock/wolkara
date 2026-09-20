#!/usr/bin/env python3
"""Validate an app profile (profiles/*.json). Profiles are data only."""
import json
import sys
from pathlib import Path, PurePosixPath

REQUIRED = ('id', 'name', 'workingDirectory', 'executable')
OPTIONAL = ('notes', 'tested')


def check(path):
    profile = json.loads(Path(path).read_text())
    if not isinstance(profile, dict): raise ValueError('profile must be a JSON object')
    unknown = set(profile) - set(REQUIRED) - set(OPTIONAL)
    if unknown: raise ValueError('unknown keys: ' + ', '.join(sorted(unknown)))
    for key in REQUIRED:
        if not isinstance(profile.get(key), str) or not profile[key]: raise ValueError(f'{key} must be a non-empty string')
    for key in ('workingDirectory', 'executable'):
        parts = PurePosixPath(profile[key]).parts
        if profile[key].startswith('/') or '..' in parts: raise ValueError(f'{key} must stay inside Documents')
    return profile


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit('usage: check_profile.py PROFILE.json')
    try: print('profile ok:', check(sys.argv[1])['id'])
    except (OSError, ValueError) as error: sys.exit(f'{sys.argv[1]}: {error}')
