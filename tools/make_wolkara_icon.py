#!/usr/bin/env python3
"""Render Wolkara's original vector mark using the repository's SVG renderer."""
import json
from pathlib import Path
from make_icon import render

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'launcher/Assets.xcassets/Wolkara.appiconset'


def svg(appearance):
    tinted = appearance == 'tinted'
    gold = '#eeeeee' if tinted else '#f1cb75'
    shade = '#9a9a9a' if tinted else '#97703a'
    glow = '#aaaaaa' if tinted else '#4edbf3'
    sky = '#252525' if tinted else '#10273d'
    # An original angular W and open portal. No game art or official logo.
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
 <radialGradient id="sky"><stop stop-color="{sky}"/><stop offset="1" stop-color="#050b14"/></radialGradient>
 <linearGradient id="gold" x2="0.2" y2="1"><stop stop-color="#fff2c0"/><stop offset=".44" stop-color="{gold}"/><stop offset="1" stop-color="{shade}"/></linearGradient>
 <linearGradient id="portal" x2=".7" y2="1"><stop stop-color="{glow}"/><stop offset="1" stop-color="{sky}"/></linearGradient>
 <filter id="glow"><feGaussianBlur stdDeviation="22"/></filter>
 <filter id="shadow"><feDropShadow dy="18" stdDeviation="12" flood-color="#000" flood-opacity=".6"/></filter>
</defs>
<rect width="1024" height="1024" fill="url(#sky)"/>
<circle cx="512" cy="500" r="347" fill="none" stroke="{glow}" stroke-width="25" opacity=".38" filter="url(#glow)"/>
<path d="M295 777 A350 350 0 1 1 729 777" fill="none" stroke="url(#portal)" stroke-width="27" stroke-linecap="round"/>
<path d="M326 749 A306 306 0 1 1 698 749" fill="none" stroke="{glow}" stroke-width="3" opacity=".5"/>
<path d="M236 317 L349 317 L409 579 L479 405 L545 405 L615 579 L675 317 L788 317 L681 720 L588 720 L512 539 L436 720 L343 720 Z"
 fill="url(#gold)" stroke="{gold}" stroke-width="4" stroke-linejoin="round" filter="url(#shadow)"/>
<path d="M249 329 L339 329 L407 622 L491 417 L533 417 L617 622 L685 329 L775 329"
 fill="none" stroke="#fff7db" stroke-width="5" opacity=".65"/>
<path d="M512 165 L533 196 L512 227 L491 196 Z" fill="{gold}"/>
<path d="M476 829 L512 799 L548 829 L512 855 Z" fill="{glow}"/>
</svg>'''


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    artwork = ROOT / 'artwork/wolkara'
    artwork.mkdir(parents=True, exist_ok=True)
    images = []
    for appearance in ('default', 'dark', 'tinted'):
        source = svg(appearance)
        (artwork / f'{appearance}.svg').write_text(source)
        filename = f'Wolkara-{appearance}.png'
        render(source, OUT / filename)
        image = {'filename': filename, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}
        if appearance != 'default':
            image['appearances'] = [{'appearance': 'luminosity', 'value': appearance}]
        images.append(image)
    (OUT / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2)+'\n')
    print(f'Wolkara icon: {OUT.relative_to(ROOT)}')
