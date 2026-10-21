# Corrected-logo app icon (2026-10-17)

The user approved matching the icon to the corrected logo. The source
`wolkara/Shell/artwork/wolkara-icon-source.png` adapts the gold W medallion from
`logo.png`; the full logo remains unchanged and tracked. Built-in imagegen was
used once for the adaptation, with this prompt:

> Create a square 1024x1024 opaque iPad app icon derived directly from this corrected Wolkara Forever logo. Use case: precise-object-edit. Retain the exact ornate golden W medallion at the bottom of the supplied logo, enlarged to dominate the square and be legible at 40 pixels. Preserve its golden pointed circular frame, blue jewel background, gold W letter and polished illustrated fantasy style. Use a dark navy background filling the entire square. Only the existing W medallion, no characters, no extra lettering, no WK monogram, no new symbols, no rounded corners (iOS supplies the mask). The W medallion should occupy about 80 percent of the canvas, centered, with all pointed edges intact. This is an icon adaptation of the existing emblem, not a redesigned brand.

Regenerate all three asset appearances with:

```sh
python3 wolkara/tools/make_wolkara_icon.py
```

This uses the committed source, the vendored SVG renderer, Chrome and `sips`.
It writes to the layer's asset catalog, not a nonexistent root launcher directory.
Default and dark share the dark artwork; tinted is monochrome. The output is opaque,
1024 square, and Xcode generates device sizes. Every distinct device pixel size below the
1024 the asset is drawn at has a preview in ignored `build/icon-previews/`; the 1024 itself
is the asset, not a preview of it.
The generator never calls imagegen or modifies `platform/`.
