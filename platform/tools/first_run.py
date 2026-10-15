"""Settings a game saves the first time it starts on the Mac (setup.firstRun in a profile).

World of Warcraft keeps its region and languages in WTF/Config.wtf, in lines such
as `SET portal "eu"`, written when the game is first started from Battle.net. A
copy of a game that never started on the Mac has no such file; on the device the
game then asks for a region in a window Tolkara cannot show yet, and quits within
a second. Only the keys the profile names are read and copied: account names and
other settings stay on the Mac. Tolkara Management follows the same rules
(management/App/Core/FirstRun.swift).
"""
import json
import re
import subprocess
import tempfile
from pathlib import Path

LINE = re.compile(r'SET ([A-Za-z0-9_]+) "([A-Za-z0-9_-]+)"')
KEY = re.compile(r'SET ([A-Za-z0-9_]+)\s')


def first_run(profile_folder):
    """The profile's setup.firstRun block: {settings, keys, steps}."""
    return json.loads((Path(profile_folder) / 'profile.json').read_text())['setup']['firstRun']


def saved(text, keys):
    """{key: value} for each named key that has a plain value in the text."""
    values = {}
    for line in text.splitlines():
        match = LINE.fullmatch(line.strip())
        if match and match[1] in keys: values[match[1]] = match[2]
    return values


def read(path, keys):
    try: return saved(Path(path).read_text(errors='replace'), keys)
    except OSError: return {}


def missing(values, keys):
    return [key for key in keys if key not in values]


def merge(text, values):
    """The text with each key set to its value: a line already there is replaced
    in place, a missing one is added. Every other line is kept as it is."""
    lines, done = [], set()
    for line in text.splitlines():
        match = KEY.match(line.strip() + ' ')
        if match and match[1] in values:
            if match[1] in done: continue
            line = f'SET {match[1]} "{values[match[1]]}"'
            done.add(match[1])
        lines.append(line)
    lines += [f'SET {key} "{value}"' for key, value in values.items() if key not in done]
    return '\n'.join(lines) + '\n'


def device_text(device, bundle_id, path):
    """The file at `path` in the app's container on the device, or '' when it is not there."""
    with tempfile.TemporaryDirectory() as folder:
        local = Path(folder) / Path(path).name
        result = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device,
                                 '--domain-type', 'appDataContainer', '--domain-identifier', bundle_id,
                                 '--source', path, '--destination', str(local)], capture_output=True)
        if result.returncode or not local.is_file(): return ''
        return local.read_text(errors='replace')


def stage(source, stage_folder, destination, profile_folder, device, bundle_id):
    """Puts the Mac's first-run settings, merged into the device's own copy of the
    file, into the staged folder that becomes Documents/<destination>. Raises
    SystemExit with what to do when neither the Mac nor the device has them."""
    block = first_run(profile_folder)
    keys, relative = block['keys'], block['settings']
    staged = Path(stage_folder) / relative
    staged.unlink(missing_ok=True)
    mac = read(Path(source) / relative, keys)
    on_device = device_text(device, bundle_id, f'Documents/{destination}/{relative}')
    if missing(mac, keys):
        if not missing(saved(on_device, keys), keys):
            print(f'{relative} on this Mac has no region and language; keeping the ones already on the device.')
            return
        raise SystemExit(f'{relative} on this Mac has no ' + ', '.join(missing(mac, keys)) + '.\n'
                         'The game has not been started on this Mac yet, so it has no region and language to copy, '
                         'and on the device it would quit right after it starts.\n'
                         + '\n'.join(f'  {index}. {re.sub(r"[*]{2}", "", step)}' for index, step in enumerate(block['steps'], 1))
                         + '\nThen run this script again (with --skip-data if Data was already copied).')
    staged.parent.mkdir(parents=True, exist_ok=True)
    staged.write_text(merge(on_device, mac))
    print('Region and language from this Mac: ' + ', '.join(f'{key} {mac[key]}' for key in keys))
