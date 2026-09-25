#!/usr/bin/env python3
"""Validate an app profile (profiles/*.json). Profiles are data only."""
import json
import sys
from pathlib import Path, PurePosixPath

REQUIRED = ('id', 'name', 'workingDirectory', 'executable')
OPTIONAL = ('notes', 'tested', 'caseAliases')


def relative(value):
    """A non-empty relative path without empty, '.' or '..' components, as the launcher requires."""
    return (isinstance(value, str) and value and not value.startswith('/') and
            all(part not in ('', '.', '..') for part in value.split('/')))


def check_case_aliases(aliases):
    """caseAliases: {alias: target}. The launcher links each alias, a path inside the working
    directory, to target, a name in the same folder that differs from the alias's last component
    only in case: iPadOS's file system is case-sensitive, macOS's default is not."""
    if not isinstance(aliases, dict): raise ValueError('caseAliases must be an object mapping alias to target')
    for alias, target in aliases.items():
        if not relative(alias): raise ValueError(f'caseAliases: {alias!r} must stay inside the working directory')
        leaf = alias.rsplit('/', 1)[-1]
        if not relative(target) or '/' in target or target == leaf or target.lower() != leaf.lower():
            raise ValueError(f'caseAliases: {alias!r} -> {target!r} must name {leaf!r} in another case')


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
    if 'caseAliases' in profile: check_case_aliases(profile['caseAliases'])
    return profile


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit('usage: check_profile.py PROFILE.json')
    try: print('profile ok:', check(sys.argv[1])['id'])
    except (OSError, ValueError) as error: sys.exit(f'{sys.argv[1]}: {error}')
