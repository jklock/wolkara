#!/usr/bin/env python3
"""Render the approved logo medallion into the layer's app icon appearances.

Run from any directory. Chrome renders the SVG composition; sips makes size
previews. Xcode derives device sizes from the three universal 1024px assets.
The source is committed, so regeneration never calls an image service.
"""
import base64
import importlib.util
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'wolkara/Shell/Assets.xcassets/Wolkara.appiconset'
ART = ROOT / 'wolkara/Shell/artwork'
PREVIEWS = ROOT / 'build/icon-previews'
spec = importlib.util.spec_from_file_location('platform_icon', ROOT / 'platform/tools/make_icon.py')
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def svg(appearance):
    source = base64.b64encode((ART / 'wolkara-icon-source.png').read_bytes()).decode()
    effect = ' filter="url(#gray)"' if appearance == 'tinted' else ''
    # Inset the approved emblem so its points remain inside the iPad corner mask.
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">
<defs><filter id="gray"><feColorMatrix type="saturate" values="0"/></filter></defs>
<rect width="1024" height="1024" fill="{'#050505' if appearance == 'tinted' else '#001638'}"/>
<image x="48" y="48" width="928" height="928" href="data:image/png;base64,{source}"{effect}/>
</svg>'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    images = []
    for appearance in ('default', 'dark', 'tinted'):
        filename = f'Wolkara-{appearance}.png'
        renderer.render(svg(appearance), OUT / filename)
        # Strip alpha: an app icon must be opaque, including its square corners.
        subprocess.run(['sips', '-s', 'format', 'bmp', str(OUT / filename), '--out', str(PREVIEWS / 'opaque.bmp')], check=True, capture_output=True)
        subprocess.run(['sips', '-s', 'format', 'png', str(PREVIEWS / 'opaque.bmp'), '--out', str(OUT / filename)], check=True, capture_output=True)
        image = {'filename': filename, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}
        if appearance != 'default':
            image['appearances'] = [{'appearance': 'luminosity', 'value': appearance}]
        images.append(image)
        for size in (40, 58, 60, 76, 80, 87, 114, 120, 128, 136, 152, 167, 180, 192):
            subprocess.run(['sips', '-z', str(size), str(size), str(OUT / filename), '--out', str(PREVIEWS / f'{appearance}-{size}.png')], check=True, capture_output=True)
    (PREVIEWS / 'opaque.bmp').unlink()
    (OUT / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    print(f'Wolkara icon: {OUT}; size previews: {PREVIEWS}')


if __name__ == '__main__':
    main()
