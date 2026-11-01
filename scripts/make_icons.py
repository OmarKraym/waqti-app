# Generates the PWA icons: a clock inside a double-ring stamp on ink #101C30.
import sys
from PIL import Image, ImageDraw

out = sys.argv[1]
BRAND = (16, 28, 48, 255)
WHITE = (255, 255, 255, 255)
ACCENT = (140, 165, 240, 255)

def icon(size, maskable=False, rounded=True):
    s = size * 4  # draw large, then downscale for smooth edges
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if maskable or not rounded:
        d.rectangle([0, 0, s, s], fill=BRAND)
    else:
        d.rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * 0.22), fill=BRAND)
    scale = 0.27 if maskable else 0.33  # maskable keeps the clock in the safe zone
    c, r = s / 2, s * scale
    w = int(s * 0.055)
    d.ellipse([c - r, c - r, c + r, c + r], outline=WHITE, width=w)
    r2 = r * 1.2  # outer ring: the second frame of a date stamp
    d.ellipse([c - r2, c - r2, c + r2, c + r2], outline=WHITE, width=max(2, w // 3))
    d.line([c, c, c, c - r * 0.62], fill=WHITE, width=w)            # minute hand
    d.line([c, c, c + r * 0.45, c + r * 0.12], fill=ACCENT, width=w)  # hour hand
    d.ellipse([c - w, c - w, c + w, c + w], fill=WHITE)
    return img.resize((size, size), Image.LANCZOS)

icon(192).save(f"{out}/icon-192.png")
icon(512).save(f"{out}/icon-512.png")
icon(512, maskable=True).save(f"{out}/icon-maskable-512.png")
icon(180, rounded=False).save(f"{out}/apple-touch-icon.png")
