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
    # An original WK monogram and open portal. Paths keep it font-independent.
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
<path d="M198 340 L274 340 L316 579 L360 431 L412 431 L456 579 L498 340 L570 340 L498 700 L426 700 L386 549 L346 700 L274 700 Z"
 fill="url(#gold)" stroke="{gold}" stroke-width="4" stroke-linejoin="round" filter="url(#shadow)"/>
<path d="M208 352 L264 352 L315 621 L371 443 L401 443 L457 621 L508 352 L557 352"
 fill="none" stroke="#fff7db" stroke-width="5" opacity=".65"/>
<path d="M592 340 L666 340 L666 481 L755 340 L842 340 L724 515 L846 700 L754 700 L666 555 L666 700 L592 700 Z"
 fill="url(#gold)" stroke="{gold}" stroke-width="4" stroke-linejoin="round" filter="url(#shadow)"/>
<path d="M604 687 L604 352 L654 352 M675 488 L765 352 L826 352 M730 532 L822 687"
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
