# Windows Clippy 25 — attached SVG / token measurement analysis

## Source facts
- Attached SVG is a reference wrapper around an embedded PNG, not an editable vector drawing.
- SVG/viewBox: `0 0 1015 1549`.
- Embedded raster: `1015 × 1549`, RGBA.
- Non-transparent bbox: `x=116..910`, `y=44..1471`.

## dar.bot memory/network token measurements
- Token visible bbox from saturated/antialiased region: `x=526..910`, `y=1066..1468`.
- Circle fit for visible outer token disk/rim: center ≈ `(718, 1274)`, radius ≈ `193 px`.
- White inner globe ring fit: center ≈ `(718, 1274)`, radius ≈ `168 px`.
- The token is not a generic flat coin; it is a dar.bot browser-style gradient globe mark embedded as a lower-right badge.

## Correction for next SVG pass
- Use the attached raster as a locked reference layer.
- Include a non-export `bitdot-grid-measurement-layer` in the SVG.
- Rebuild the token against the measured center/radius and grid, not by approximating with a generic coin symbol.
- Keep the white globe grid as negative-space-like grid lines over the magenta/purple/blue/cyan disk.
- Keep the diagonal lightning bolt large and boundary-breaking; do not use the old yellow-bolt token.
