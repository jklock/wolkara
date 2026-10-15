#!/usr/bin/env python3
"""Draw the Tolkara app icon and render every iOS icon size into the asset catalog.

The mark: a gilded T with a blue gem, set in a ring over a night landscape.
Three levels of detail keep it legible from the App Store size down to
notifications: 'full' (1024 px), 'medium' (home screen: no texture, stars or
windows) and 'small' (Spotlight, Settings, notifications: thicker ring, no
spikes, a single horizon). Each size is rendered in the default, dark and
tinted appearances.

    python3 tools/make_icon.py              # write launcher/Assets.xcassets/AppIcon.appiconset
    python3 tools/make_icon.py --svg DIR    # also keep the nine SVG sources in DIR

Rendering uses headless Chrome (override with $CHROME) and macOS sips. Nothing
here is loaded by the app; the PNGs are the build input.
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

S = 1024
ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / 'launcher/Assets.xcassets/AppIcon.appiconset'
CHROME = os.environ.get('CHROME', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
APPEARANCES = {'default': 'AppIcon', 'dark': 'AppIcon-Dark', 'tinted': 'AppIcon-Tinted'}
# Xcode's "All Sizes" set for iOS and iPadOS: (points, scale).
SIZES = [('20', 2), ('20', 3), ('29', 2), ('29', 3), ('38', 2), ('38', 3), ('40', 2), ('40', 3), ('60', 2), ('60', 3),
         ('64', 2), ('64', 3), ('68', 2), ('76', 2), ('83.5', 2), ('1024', 1)]

CX = 512
RING_C = (512, 497)
RING_OUT, RING_IN = 430, 398
G = 3                        # half of the seam between the two halves of the T
# Left half of the T: a horned arm and half of the stem. The right half is its mirror.
HALF_T = [
    ('M', (CX - G, 172)),
    ('L', (452, 224)),
    ('C', (380, 230), (250, 222), (152, 162)),       # top edge to the upper horn tip
    ('C', (192, 230), (188, 330), (160, 408)),       # outer edge to the lower horn tip
    ('C', (192, 334), (252, 284), (322, 284)),       # underside up to the window's apex
    ('C', (382, 284), (420, 322), (420, 398)),       # down into the stem
    ('L', (420, 728)),
    ('C', (412, 758), (392, 778), (364, 792)),       # barb
    ('C', (432, 808), (488, 872), (CX - G, 950)),    # to the point
]
BEZEL = [(512, 198), (576, 306), (512, 414), (448, 306)]
GEM = [(512, 228), (552, 306), (512, 384), (472, 306)]
GEM_C = (512, 306)
CASTLE = ('M90,700 L120,640 L150,620 L160,560 L166,560 L168,520 L173,494 L178,520 L180,560 L192,560 L192,480 L198,470 '
          'L203,430 L208,470 L214,480 L214,540 L224,540 L224,440 L230,430 L237,372 L244,430 L250,440 L250,540 L262,540 '
          'L262,492 L267,484 L272,452 L277,484 L282,492 L282,556 L292,556 L292,520 L296,514 L300,490 L304,514 L308,520 '
          'L308,580 L326,600 L360,640 L400,660 L420,700 Z')
WINDOWS = [(234, 470), (234, 500), (202, 500), (270, 512), (180, 580), (252, 580), (296, 548)]
STARS = [(180, 330, 1.8, 0.8), (280, 250, 1.4, 0.6), (740, 300, 1.8, 0.8), (860, 380, 1.4, 0.6), (650, 420, 1.2, 0.5),
         (120, 480, 1.2, 0.5), (900, 470, 1.4, 0.5)]


def xy(p):
    return f'{p[0]:.1f},{p[1]:.1f}'


def polygon(points):
    return 'M' + ' L'.join(xy(p) for p in points) + ' Z'


def half_t(mirror=False):
    flip = (lambda p: (S - p[0], p[1])) if mirror else (lambda p: p)
    return ' '.join(op + ' '.join(xy(flip(p)) for p in points) for op, *points in HALF_T) + ' Z'


def detail_for(pixels):
    return 'full' if pixels >= 300 else 'medium' if pixels >= 100 else 'small'


def spikes():
    """Four-sided studs on the ring; the facet facing the light (top left) is the bright one."""
    out = []
    for deg in (90, 0, 180, 225, 315):
        ux, uy = math.cos(math.radians(deg)), -math.sin(math.radians(deg))
        px, py = -uy, ux
        at = lambda r: (RING_C[0] + ux * r, RING_C[1] + uy * r)
        tip, base, mid = at(RING_OUT + 42), at(RING_IN - 6), at(RING_OUT - 2)
        side_a, side_b = (mid[0] + px * 17, mid[1] + py * 17), (mid[0] - px * 17, mid[1] - py * 17)
        lit, dark = ('url(#spikeLit)', 'url(#spikeDark)') if px + py < 0 else ('url(#spikeDark)', 'url(#spikeLit)')
        out.append(f'<path d="{polygon([tip, side_a, base])}" fill="{lit}"/><path d="{polygon([tip, side_b, base])}" fill="{dark}"/>')
    return ''.join(out)


def landscape(detail, c):
    parts = [f'<rect width="{S}" height="{S}" fill="url(#sky)"/>',
             '<circle cx="704" cy="592" r="120" fill="url(#moonGlow)"/><circle cx="704" cy="592" r="44" fill="url(#moon)"/>']
    if detail == 'small':
        parts.append(f'<path d="M60,690 C200,650 330,660 512,690 C690,650 830,650 960,690 L960,960 L60,960 Z" fill="{c("#0E1D4C", "#1C1C1C")}"/>')
        return ''.join(parts)
    parts += [
        f'<path d="M560,640 L612,606 L648,618 L690,578 L716,600 L742,588 L770,612 L806,574 L850,616 L900,600 L960,640 L960,700 L560,700 Z" fill="{c("#4668B0", "#555555")}"/>',
        f'<path d="M700,660 L788,540 L832,470 L850,500 L872,512 L930,600 L960,640 L960,700 L700,700 Z" fill="{c("#243F80", "#3A3A3A")}"/>',
        f'<path d="M832,470 L790,560 L760,640 L790,640 L812,590 L826,540 Z" fill="{c("#4B6DB6", "#4A4A4A")}" opacity="0.9"/>',
        f'<path d="{CASTLE}" fill="{c("#132659", "#262626")}"/>',
    ]
    if detail == 'full':
        parts += [f'<rect x="{x}" y="{y}" width="5" height="9" rx="1.5" fill="{c("#FFC56B", "#DDDDDD")}" opacity="0.9"/>' for x, y in WINDOWS]
    parts += [
        f'<rect x="0" y="686" width="{S}" height="{S}" fill="{c("#16296A", "#2A2A2A")}"/>',
        '<path d="M700,640 C716,650 704,664 690,672 C668,686 700,700 736,712 C778,726 760,760 720,780 L800,800 '
        'C840,770 830,730 780,708 C744,694 724,682 736,670 C748,660 740,646 712,640 Z" fill="url(#river)"/>',
        f'<path d="M60,760 C140,700 240,690 330,720 C380,736 410,750 430,770 L430,960 L60,960 Z" fill="{c("#0E1D4C", "#1C1C1C")}"/>',
        f'<path d="M600,770 C660,730 700,760 720,790 C760,760 850,740 960,760 L960,960 L600,960 Z" fill="{c("#0E1D4C", "#1C1C1C")}"/>',
    ]
    if detail == 'full':
        parts += [f'<circle cx="{x}" cy="{y}" r="{r}" fill="#FFFFFF" opacity="{o}"/>' for x, y, r, o in STARS]
    return ''.join(parts)


def svg(appearance='default', detail='full'):
    """default: full artwork. dark: no background (iOS supplies it). tinted: greys, the T brightest."""
    clear, tinted, small = appearance != 'default', appearance == 'tinted', detail == 'small'
    c = (lambda colour, grey: grey) if tinted else (lambda colour, grey: colour)
    left, right = half_t(), half_t(mirror=True)
    ring_w, ring_mid = (44, 410) if small else (RING_OUT - RING_IN, (RING_OUT + RING_IN) / 2)
    # The gold's surface: a blurred alpha height map, streaked with noise at full detail only.
    height = ('<feTurbulence type="fractalNoise" baseFrequency="0.018 0.11" numOctaves="3" seed="11" result="noise"/>'
              '<feColorMatrix in="noise" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0.9 0 0 0 0" result="grain"/>'
              '<feComposite in="blur" in2="grain" operator="arithmetic" k2="1" k3="0.10" k4="-0.045" result="height"/>'
              ) if detail == 'full' else '<feComposite in="blur" in2="blur" operator="arithmetic" k2="1" result="height"/>'
    background = '' if clear else f'<rect width="{S}" height="{S}" fill="url(#bg)"/><rect width="{S}" height="{S}" fill="url(#vignette)"/>'
    g0, g1, g2, g3 = GEM
    gem = (f'<path d="{polygon([g0, g3, GEM_C])}" fill="{c("#9FE6FF", "#FFFFFF")}"/>'
           f'<path d="{polygon([g0, g1, GEM_C])}" fill="{c("#3FA2FF", "#D8D8D8")}"/>'
           f'<path d="{polygon([g3, g2, GEM_C])}" fill="{c("#1C5BD8", "#B8B8B8")}"/>'
           f'<path d="{polygon([g1, g2, GEM_C])}" fill="{c("#0B2E8C", "#8C8C8C")}"/>'
           f'<path d="{polygon([(512, 250), (538, 306), (512, 362), (486, 306)])}" fill="{c("#62C4FF", "#EEEEEE")}" opacity="0.55"/>')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">
  <defs>
    <radialGradient id="bg" cx="512" cy="430" r="720" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#21407E"/><stop offset="0.6" stop-color="#132A5C"/><stop offset="1" stop-color="#0A1636"/>
    </radialGradient>
    <radialGradient id="vignette" cx="512" cy="512" r="760" gradientUnits="userSpaceOnUse">
      <stop offset="0.6" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="0.35"/>
    </radialGradient>
    <linearGradient id="sky" x1="0" y1="100" x2="0" y2="700" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{c('#0A1742', '#1A1A1A')}"/><stop offset="0.55" stop-color="{c('#1C3C88', '#383838')}"/>
      <stop offset="0.9" stop-color="{c('#4471C4', '#5A5A5A')}"/><stop offset="1" stop-color="{c('#6B8FD2', '#6A6A6A')}"/>
    </linearGradient>
    <radialGradient id="moon" cx="0.4" cy="0.35" r="0.7">
      <stop offset="0" stop-color="{c('#FFF0DC', '#FFFFFF')}"/><stop offset="1" stop-color="{c('#F0B48E', '#CFCFCF')}"/>
    </radialGradient>
    <radialGradient id="moonGlow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="{c('#F7C29A', '#FFFFFF')}" stop-opacity="0.55"/><stop offset="1" stop-color="{c('#F7C29A', '#FFFFFF')}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="river" x1="0" y1="640" x2="0" y2="800" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{c('#B9D2F5', '#BBBBBB')}"/><stop offset="1" stop-color="{c('#3C63B0', '#555555')}"/>
    </linearGradient>
    <linearGradient id="gold" x1="0" y1="160" x2="0" y2="950" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{c('#FFE39A', '#FFFFFF')}"/><stop offset="0.3" stop-color="{c('#F2B84E', '#EDEDED')}"/>
      <stop offset="0.7" stop-color="{c('#D08A2C', '#D6D6D6')}"/><stop offset="1" stop-color="{c('#8E5214', '#BDBDBD')}"/>
    </linearGradient>
    <linearGradient id="ringGold" x1="0" y1="60" x2="0" y2="940" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{c('#F0C774', '#E0E0E0')}"/><stop offset="0.5" stop-color="{c('#C48A38', '#BDBDBD')}"/>
      <stop offset="1" stop-color="{c('#8A5418', '#9A9A9A')}"/>
    </linearGradient>
    <linearGradient id="bezel" x1="0" y1="198" x2="0" y2="414" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{c('#7A4510', '#A0A0A0')}"/><stop offset="1" stop-color="{c('#3A1F06', '#707070')}"/>
    </linearGradient>
    <linearGradient id="spikeLit" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{c('#FFE6A6', '#FFFFFF')}"/><stop offset="1" stop-color="{c('#D9A24E', '#D0D0D0')}"/>
    </linearGradient>
    <linearGradient id="spikeDark" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{c('#B07A34', '#A8A8A8')}"/><stop offset="1" stop-color="{c('#6E4516', '#808080')}"/>
    </linearGradient>
    <radialGradient id="gemGlow" cx="512" cy="306" r="150" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{c('#5AB8FF', '#FFFFFF')}" stop-opacity="0.9"/><stop offset="1" stop-color="{c('#5AB8FF', '#FFFFFF')}" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="inside"><circle cx="{RING_C[0]}" cy="{RING_C[1]}" r="{ring_mid - ring_w / 2 + 1}"/></clipPath>
    <filter id="metal" x="-5%" y="-5%" width="110%" height="110%" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="{3 if small else 6}" result="blur"/>
      {height}
      <feSpecularLighting in="height" surfaceScale="{6 if small else 9}" specularConstant="1.25" specularExponent="26" lighting-color="{c('#FFF1CC', '#FFFFFF')}" result="spec">
        <feDistantLight azimuth="225" elevation="34"/>
      </feSpecularLighting>
      <feComposite in="spec" in2="SourceAlpha" operator="in" result="specIn"/>
      <feDiffuseLighting in="height" surfaceScale="{6 if small else 9}" diffuseConstant="1.25" lighting-color="#FFFFFF" result="diffuse">
        <feDistantLight azimuth="225" elevation="58"/>
      </feDiffuseLighting>
      <feComposite in="SourceGraphic" in2="diffuse" operator="arithmetic" k1="1" result="lit"/>
      <feComposite in="lit" in2="specIn" operator="arithmetic" k2="1" k3="0.85" result="shine"/>
      <feComposite in="shine" in2="SourceAlpha" operator="in"/>
    </filter>
    <filter id="blueGlow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="{10 if small else 14}"/></filter>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="120%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="8"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.55"/></feComponentTransfer>
    </filter>
    <filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3"/></filter>
  </defs>
  {background}
  <g clip-path="url(#inside)">{landscape(detail, c)}</g>
  <circle cx="{RING_C[0]}" cy="{RING_C[1]}" r="{ring_mid}" fill="none" stroke="{c('#2F86FF', '#FFFFFF')}" stroke-width="{ring_w + 26}" opacity="{0.35 if tinted else 0.85}" filter="url(#blueGlow)"/>
  <g filter="url(#metal)">
    <circle cx="{RING_C[0]}" cy="{RING_C[1]}" r="{ring_mid}" fill="none" stroke="url(#ringGold)" stroke-width="{ring_w}"/>
    {'' if small else spikes()}
  </g>
  <g filter="url(#shadow)"><path d="{left}"/><path d="{right}"/></g>
  <path d="M{CX - G - 1},176 L{CX + G + 1},176 L{CX + G + 1},946 L{CX},952 L{CX - G - 1},946 Z" fill="{c('#4A2A08', '#606060')}"/>
  <g filter="url(#metal)"><path d="{left}" fill="url(#gold)"/><path d="{right}" fill="url(#gold)"/></g>
  <path d="{polygon(BEZEL)}" fill="url(#bezel)" stroke="{c('#F7CF7A', '#FFFFFF')}" stroke-width="{6 if small else 4}"/>
  <circle cx="512" cy="306" r="150" fill="url(#gemGlow)" opacity="{0.35 if small else 0.55}"/>
  {gem}
  <path d="{polygon(GEM)}" fill="none" stroke="{c('#D8F3FF', '#FFFFFF')}" stroke-width="3" opacity="0.7"/>
  <circle cx="496" cy="276" r="7" fill="#FFFFFF" opacity="0.9" filter="url(#soft)"/>
</svg>
'''


def render(svg_text, png):
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / 'icon.html'
        page.write_text(f'<html><body style="margin:0;background:transparent">{svg_text}</body></html>')
        subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
                        '--default-background-color=00000000', f'--window-size={S},{S}', f'--screenshot={png}',
                        page.as_uri()], check=True, capture_output=True)


def filename(prefix, points, scale):
    return f'{prefix}-{points}.png' if points == '1024' else f'{prefix}-{points}@{scale}x.png'


def contents():
    images = []
    for appearance, prefix in APPEARANCES.items():
        for points, scale in SIZES:
            image = {'filename': filename(prefix, points, scale), 'idiom': 'universal', 'platform': 'ios',
                     'scale': f'{scale}x', 'size': f'{points}x{points}'}
            if points == '1024': del image['scale']
            if appearance != 'default': image['appearances'] = [{'appearance': 'luminosity', 'value': appearance}]
            images.append(image)
    return json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--svg', type=Path, help='also write the SVG sources to this directory')
    args = parser.parse_args()
    if not os.access(CHROME, os.X_OK): sys.exit(f'Google Chrome not found at {CHROME}; set $CHROME')
    if args.svg: args.svg.mkdir(parents=True, exist_ok=True)
    for old in ICONSET.glob('*.png'): old.unlink()
    with tempfile.TemporaryDirectory() as tmp:
        for appearance, prefix in APPEARANCES.items():
            masters = {}
            for detail in ('full', 'medium', 'small'):
                text = svg(appearance, detail)
                if args.svg: (args.svg / f'{prefix}-{detail}.svg').write_text(text)
                masters[detail] = Path(tmp) / f'{prefix}-{detail}.png'
                render(text, masters[detail])
            for points, scale in SIZES:
                pixels = round(float(points) * scale)
                out = ICONSET / filename(prefix, points, scale)
                if pixels == S: shutil.copyfile(masters['full'], out)
                else: subprocess.run(['sips', '-z', str(pixels), str(pixels), str(masters[detail_for(pixels)]), '--out', str(out)],
                                     check=True, capture_output=True)
    (ICONSET / 'Contents.json').write_text(contents())
    print(f'wrote {len(APPEARANCES) * len(SIZES)} images to {ICONSET.relative_to(ROOT)}')
