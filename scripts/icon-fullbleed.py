#!/usr/bin/env python3
"""
Turns a rounded-square app icon (with transparent corners and a baked-in bevel) into full-bleed square
artwork for macOS, which applies its own icon shape: the bevel band is dropped, the corners are filled by
growing the nearby colors outward, and the edge is trimmed.

    python3 scripts/icon-fullbleed.py docs/design/icon/piopio-icon-light-original.png light.png
    python3 scripts/icon-fullbleed.py docs/design/icon/piopio-icon-dark-original.png dark.png

The results go in apps/mac/App/Piopio/AppIcon.icon/Assets/ (chick-light.png, chick-dark.png).
Needs Pillow and numpy.
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

src, dst = sys.argv[1], sys.argv[2]
INSET = 18  # drops the baked-in bevel and border
im = Image.open(src).convert("RGBA")
w, h = im.size
im = im.crop((INSET, INSET, w - INSET, h - INSET))
a = np.array(im).astype(np.float32)
alpha = a[..., 3] > 250
# The bevel ring follows the old rounded edge: drop a band along it too, then refill from inside.
mask = Image.fromarray((alpha * 255).astype(np.uint8))
for _ in range(4):
    mask = mask.filter(ImageFilter.MinFilter(15))
alpha = np.array(mask) > 0
rgb = a[..., :3]
# Grow opaque colors into the transparent corners: repeated 3x3 averaging of known pixels.
known = alpha.copy()
filled = rgb * known[..., None]
for _ in range(600):
    if known.all():
        break
    k = known.astype(np.float32)
    pad = lambda x: np.pad(x, ((1, 1), (1, 1)) + ((0, 0),) * (x.ndim - 2), mode="edge")
    ks, fs = pad(k), pad(filled)
    nsum = sum(ks[1 + dy:ks.shape[0] - 1 + dy, 1 + dx:ks.shape[1] - 1 + dx] for dy in (-1, 0, 1) for dx in (-1, 0, 1))
    fsum = sum(fs[1 + dy:fs.shape[0] - 1 + dy, 1 + dx:fs.shape[1] - 1 + dx] for dy in (-1, 0, 1) for dx in (-1, 0, 1))
    grow = (~known) & (nsum > 0)
    filled[grow] = fsum[grow] / nsum[grow][:, None]
    known = known | grow
out = Image.fromarray(np.clip(filled, 0, 255).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS)
out = out.crop((14, 14, 1010, 1010)).resize((1024, 1024), Image.LANCZOS)  # trim what's left of the edge
out.save(dst)
print(dst)
