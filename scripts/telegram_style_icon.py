# Telegram-style icon: blue diagonal gradient + one bold white glyph
# (a document with two-way transfer arrows knocked out of it).
# usage: telegram_style_icon.py out_tile.png
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1104      # tile size (prepare_icon.py masks & places it)
K = 4         # supersampling

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# Telegram-like gradient: light sky blue top-left -> deep blue bottom-right
TOP, BOTTOM = (64, 190, 246), (21, 128, 214)
grad = Image.new("RGB", (S, S))
gp = grad.load()
for y in range(S):
    for x in range(S):
        t = (x * 0.35 + y * 0.65) / S
        gp[x, y] = lerp(TOP, BOTTOM, min(1, max(0, t)))
BG_WHITE = True   # white tile; arrows keep the blue gradient
if BG_WHITE:
    bgimg = Image.new("RGB", (S, S))
    bd = ImageDraw.Draw(bgimg)
    for y in range(S):
        bd.line([(0, y), (S, y)], fill=lerp((255, 255, 255), (242, 244, 247), y / S))
    out = bgimg.convert("RGBA")
else:
    out = grad.convert("RGBA")

def mask(fn):
    m = Image.new("L", (S * K, S * K), 0)
    fn(ImageDraw.Draw(m), K)
    return m.resize((S, S), Image.LANCZOS)

# --- document geometry ---
W, H = int(S * 0.46), int(S * 0.58)
x0, y0 = (S - W) // 2, (S - H) // 2
x1, y1 = x0 + W, y0 + H
r = int(S * 0.05)
fold = int(S * 0.15)

def doc(d, k):
    # rounded body with the top-right corner cut diagonally
    d.rounded_rectangle((x0 * k, y0 * k, x1 * k, y1 * k), radius=r * k, fill=255)
    d.polygon([((x1 - fold) * k, (y0 - 2) * k), ((x1 + 2) * k, (y0 - 2) * k), ((x1 + 2) * k, (y0 + fold) * k)], fill=0)

doc_m = mask(doc)

# soft shadow
sh = Image.new("RGBA", (S, S), ((120, 80, 0, 0) if BG_WHITE else (8, 50, 120, 0)))
sh.putalpha(doc_m.point(lambda v: v * (55 if BG_WHITE else 80) // 255))
sh = sh.filter(ImageFilter.GaussianBlur(22))
out.alpha_composite(sh, (0, 18))

# yellow file: warm vertical gradient
yel = Image.new("RGBA", (S, S))
yd = ImageDraw.Draw(yel)
for y in range(S):
    t = min(1, max(0, (y - y0) / H))
    yd.line([(0, y), (S, y)], fill=lerp((255, 214, 72), (255, 168, 0), t) + (255,))
out.paste(yel, (0, 0), doc_m)

# folded corner (slightly tinted white)
fold_m = mask(lambda d, k: d.polygon([
    ((x1 - fold) * k, y0 * k),
    ((x1 - fold) * k, (y0 + fold - r * 0.6) * k),
    ((x1 - fold + r * 0.6) * k, (y0 + fold) * k),
    (x1 * k, (y0 + fold) * k)], fill=255))
out.paste(Image.new("RGBA", (S, S), (255, 236, 160, 255)), (0, 0), fold_m)

# --- two-way arrows knocked out (show gradient through) ---
cx = S // 2
cy = y0 + int(H * 0.60)
L = int(W * 0.62)        # arrow length
th = int(S * 0.034)      # shaft thickness
hw = int(S * 0.062)      # head half-height
hl = int(S * 0.075)      # head length
gap = int(S * 0.075)
ax0, ax1 = cx - L // 2, cx + L // 2

def arrows(d, k):
    # top: → 
    yt = cy - gap
    d.rounded_rectangle((ax0 * k, (yt - th / 2) * k, (ax1 - hl + 4) * k, (yt + th / 2) * k), radius=th / 2 * k, fill=255)
    d.polygon([(ax1 * k, yt * k), ((ax1 - hl) * k, (yt - hw) * k), ((ax1 - hl) * k, (yt + hw) * k)], fill=255)
    # bottom: ←
    yb = cy + gap
    d.rounded_rectangle(((ax0 + hl - 4) * k, (yb - th / 2) * k, ax1 * k, (yb + th / 2) * k), radius=th / 2 * k, fill=255)
    d.polygon([(ax0 * k, yb * k), ((ax0 + hl) * k, (yb - hw) * k), ((ax0 + hl) * k, (yb + hw) * k)], fill=255)

arrow_m = mask(arrows)
out.paste(grad.convert("RGBA"), (0, 0), arrow_m)

out.convert("RGB").save(sys.argv[1])
print("saved", sys.argv[1])
