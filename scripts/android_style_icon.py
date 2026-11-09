# Modern Material-style icon: white tile, Android-style file with folded corner,
# white rounded two-way transfer arrows.
# usage: android_style_icon.py out_tile.png
import sys
from PIL import Image, ImageDraw, ImageFilter

S, K = 1104, 4
def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def vgrad(top, bottom, y0=0, y1=S):
    g = Image.new("RGBA", (S, S)); d = ImageDraw.Draw(g)
    for y in range(S):
        t = min(1, max(0, (y - y0) / max(1, y1 - y0)))
        d.line([(0, y), (S, y)], fill=lerp(top, bottom, t) + (255,))
    return g

def mask(fn, round_px=0):
    """Draw at K×; optionally round every corner (blur + threshold) for a soft Material look."""
    m = Image.new("L", (S * K, S * K), 0)
    fn(ImageDraw.Draw(m), K)
    if round_px:
        m = m.filter(ImageFilter.GaussianBlur(round_px * K)).point(lambda v: 255 if v > 127 else 0)
    return m.resize((S, S), Image.LANCZOS)

out = vgrad((255, 255, 255), (241, 243, 246))

# ---- Android-style file ----
W, H = int(S * 0.50), int(S * 0.62)
x0, y0 = (S - W) // 2, (S - H) // 2 + 6
x1, y1 = x0 + W, y0 + H
fold = int(W * 0.34)
R = int(S * 0.045)

body = mask(lambda d, k: (
    d.rounded_rectangle((x0*k, y0*k, x1*k, y1*k), radius=R*k, fill=255),
    d.polygon([((x1-fold)*k, (y0-5)*k), ((x1+5)*k, (y0-5)*k), ((x1+5)*k, (y0+fold)*k)], fill=0),
), round_px=10)

# shadow
sh = Image.new("RGBA", (S, S), (150, 90, 0, 0))
sh.putalpha(body.point(lambda v: v * 70 // 255))
sh = sh.filter(ImageFilter.GaussianBlur(26))
out.alpha_composite(sh, (0, 22))

out.paste(vgrad((255, 202, 40), (255, 152, 0), y0, y1), (0, 0), body)

# folded corner: lighter triangle with rounded inner corner
fold_m = mask(lambda d, k: d.polygon([
    ((x1-fold)*k, y0*k), ((x1-fold)*k, (y0+fold)*k), (x1*k, (y0+fold)*k)], fill=255), round_px=9)
out.paste(Image.new("RGBA", (S, S), (255, 228, 150, 255)), (0, 0), fold_m)
# soft shadow line under the fold for depth
fs = mask(lambda d, k: d.polygon([((x1-fold)*k, (y0+fold)*k), (x1*k, (y0+fold)*k), (x1*k, (y0+fold+16)*k), ((x1-fold+16)*k, (y0+fold+16)*k)], fill=255))
fsh = Image.new("RGBA", (S, S), (200, 110, 0, 0)); fsh.putalpha(fs.point(lambda v: v * 60 // 255))
fsh = fsh.filter(ImageFilter.GaussianBlur(6))
clip = Image.new("L", (S, S), 0); clip.paste(body, (0, 0))
tmp = Image.new("RGBA", (S, S), (0, 0, 0, 0)); tmp.alpha_composite(fsh)
out.alpha_composite(Image.composite(tmp, Image.new("RGBA", (S, S), (0, 0, 0, 0)), clip))
out.paste(Image.new("RGBA", (S, S), (255, 228, 150, 255)), (0, 0), fold_m)

# ---- white Material "swap" arrows ----
cx = S // 2
cy = y0 + int(H * 0.60)
L = int(W * 0.60)
sw = int(S * 0.046)        # stroke width
head = int(S * 0.072)      # chevron arm length (each axis)
gap = int(S * 0.082)
ax0, ax1 = cx - L // 2, cx + L // 2

def stroke(d, k, p, q):
    d.line([(p[0]*k, p[1]*k), (q[0]*k, q[1]*k)], fill=255, width=int(sw*k))
    for (x, y) in (p, q):
        d.ellipse(((x - sw/2)*k, (y - sw/2)*k, (x + sw/2)*k, (y + sw/2)*k), fill=255)

def arrows(d, k):
    yt, yb = cy - gap, cy + gap
    # → top
    stroke(d, k, (ax0, yt), (ax1, yt))
    stroke(d, k, (ax1, yt), (ax1 - head, yt - head))
    stroke(d, k, (ax1, yt), (ax1 - head, yt + head))
    # ← bottom
    stroke(d, k, (ax1, yb), (ax0, yb))
    stroke(d, k, (ax0, yb), (ax0 + head, yb - head))
    stroke(d, k, (ax0, yb), (ax0 + head, yb + head))

am = mask(arrows)
ash = Image.new("RGBA", (S, S), (190, 100, 0, 0)); ash.putalpha(am.point(lambda v: v * 90 // 255))
ash = ash.filter(ImageFilter.GaussianBlur(8))
out.alpha_composite(ash, (0, 8))
out.paste(Image.new("RGBA", (S, S), (255, 255, 255, 255)), (0, 0), am)

out.convert("RGB").save(sys.argv[1])
print("saved", sys.argv[1])
