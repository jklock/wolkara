#!/usr/bin/env python3
"""Validate an app profile (profiles/*.json). Profiles are data only."""
import json
import re
import sys
from pathlib import Path

REQUIRED = ('id', 'name', 'workingDirectory', 'executable')
OPTIONAL = ('notes', 'tested', 'caseAliases', 'runtime', 'arguments', 'environment')
ENVIRONMENT_NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')


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


def check_command_line(profile):
    """A compatibility runtime's command line (arguments, environment): plain strings, no code."""
    arguments = profile.get('arguments', [])
    if not isinstance(arguments, list) or len(arguments) > 64 or any(not isinstance(a, str) or len(a) > 4096 for a in arguments):
        raise ValueError('arguments must be a list of at most 64 strings')
    environment = profile.get('environment', {})
    if not isinstance(environment, dict) or len(environment) > 64: raise ValueError('environment must be an object of at most 64 variables')
    for name, value in environment.items():
        if not ENVIRONMENT_NAME.fullmatch(name) or len(name) > 256: raise ValueError(f'environment variable name {name!r} is invalid')
        if not isinstance(value, str) or len(value) > 4096: raise ValueError(f'environment variable {name} must be a string')


def check(path):
    profile = json.loads(Path(path).read_text())
    if not isinstance(profile, dict): raise ValueError('profile must be a JSON object')
    unknown = set(profile) - set(REQUIRED) - set(OPTIONAL)
    if unknown: raise ValueError('unknown keys: ' + ', '.join(sorted(unknown)))
    for key in REQUIRED:
        if not isinstance(profile.get(key), str) or not profile[key]: raise ValueError(f'{key} must be a non-empty string')
    for key in ('workingDirectory', 'executable', 'runtime'):
        if key in profile and not relative(profile[key]): raise ValueError(f'{key} must stay inside Documents')
    if 'caseAliases' in profile: check_case_aliases(profile['caseAliases'])
    check_command_line(profile)
    return profile


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit('usage: check_profile.py PROFILE.json')
    try: print('profile ok:', check(sys.argv[1])['id'])
    except (OSError, ValueError) as error: sys.exit(f'{sys.argv[1]}: {error}')
