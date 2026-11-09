# Composes the app icon tile: phone (from the AI image) + a macOS-style blue folder
# with two-way transfer arrows between them. Output feeds prepare_icon.py.
# usage: compose_icon.py src.png out.png
import sys
from PIL import Image, ImageDraw, ImageFilter

src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGB")
TILE = (74, 62, 1178, 1175)
PHONE = (352, 112, 912, 1135)
tile = im.crop(TILE)
TW, TH = tile.size
K = 4  # supersampling for smooth vector shapes

samples = [tile.getpixel(p) for p in [(120, TH // 2), (TW - 120, TH // 2), (TW // 2, 30), (160, 160), (TW - 160, TH - 160)]]
bg = tuple(sum(c[i] for c in samples) // len(samples) for i in range(3))
out = Image.new("RGBA", (TW, TH), bg + (255,))

# --- phone (left) ---
PHONE_SCALE = 0.60
phone = im.crop(PHONE)
pw, ph = phone.size
m = Image.new("L", (pw, ph), 0)
f = 22
ImageDraw.Draw(m).rectangle((f, f, pw - f, ph - f), fill=255)
m = m.filter(ImageFilter.GaussianBlur(f / 2))
nw, nh = int(pw * PHONE_SCALE), int(ph * PHONE_SCALE)
phone = phone.resize((nw, nh), Image.LANCZOS)
m = m.resize((nw, nh), Image.LANCZOS)
phone_cx = int(TW * 0.305)
px0, py0 = phone_cx - nw // 2, (TH - nh) // 2 + 4
out.paste(phone, (px0, py0), m)
phone_right = px0 + nw - 30  # ignore feathered shadow margin

def vgrad(w, h, top, bottom):
    g = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(g)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    return g

def shape(w, h, draw_fn):
    """Draw a mask at K× and downsample for anti-aliasing."""
    mk = Image.new("L", (w * K, h * K), 0)
    draw_fn(ImageDraw.Draw(mk), K)
    return mk.resize((w, h), Image.LANCZOS)

# --- macOS-style folder (right) ---
FW, FH = 300, 238
fx0 = int(TW * 0.725) - FW // 2
fy0 = (TH - FH) // 2 + 10
r = int(FW * 0.075)
tab_w, tab_h = int(FW * 0.40), int(FH * 0.12)
body_top = tab_h

back_mask = shape(FW, FH, lambda d, k: (
    d.rounded_rectangle((0, 0, tab_w * k, (body_top + r * 2) * k), radius=r * k, fill=255),
    d.rounded_rectangle((0, (body_top - 2) * k + r // 2 * k, FW * k, FH * k), radius=r * k, fill=255),
    d.rounded_rectangle((0, int(tab_h * 0.55) * k, FW * k, FH * k), radius=r * k, fill=255),
))
front_top = int(FH * 0.25)
front_mask = shape(FW, FH, lambda d, k: d.rounded_rectangle((0, front_top * k, FW * k, FH * k), radius=r * k, fill=255))

folder = Image.new("RGBA", (FW, FH), (0, 0, 0, 0))
folder.paste(vgrad(FW, FH, (64, 156, 240), (36, 120, 220)), (0, 0), back_mask)
folder.paste(vgrad(FW, FH, (118, 196, 255), (60, 160, 245)), (0, 0), front_mask)
# subtle highlight on front's top edge
hl = shape(FW, FH, lambda d, k: d.line([(r * k, (front_top + 3) * k), ((FW - r) * k, (front_top + 3) * k)], fill=150, width=3 * k))
folder.paste(Image.new("RGBA", (FW, FH), (255, 255, 255, 255)), (0, 0), hl)

# soft shadow under folder
sh = Image.new("RGBA", (TW, TH), (0, 0, 0, 0))
alpha = Image.new("L", (TW, TH), 0)
alpha.paste(back_mask.point(lambda v: v * 70 // 255), (fx0, fy0 + 14))
sh.putalpha(alpha)
sh = sh.filter(ImageFilter.GaussianBlur(16))
out.alpha_composite(sh)
out.alpha_composite(folder, (fx0, fy0))

# --- two-way arrows between phone and folder ---
ax0 = phone_right + 34
ax1 = fx0 - 34
cy = TH // 2 + 6
gap = 46
color = (52, 140, 238, 255)
arrows = shape(TW, TH, lambda d, k: (
    # top: phone -> folder
    d.line([(ax0 * k, (cy - gap) * k), ((ax1 - 30) * k, (cy - gap) * k)], fill=255, width=20 * k),
    d.polygon([((ax1 + 4) * k, (cy - gap) * k), ((ax1 - 40) * k, (cy - gap - 34) * k), ((ax1 - 40) * k, (cy - gap + 34) * k)], fill=255),
    d.ellipse(((ax0 - 10) * k, (cy - gap - 10) * k, (ax0 + 10) * k, (cy - gap + 10) * k), fill=255),
    # bottom: folder -> phone
    d.line([((ax0 + 30) * k, (cy + gap) * k), (ax1 * k, (cy + gap) * k)], fill=255, width=20 * k),
    d.polygon([((ax0 - 4) * k, (cy + gap) * k), ((ax0 + 40) * k, (cy + gap - 34) * k), ((ax0 + 40) * k, (cy + gap + 34) * k)], fill=255),
    d.ellipse(((ax1 - 10) * k, (cy + gap - 10) * k, (ax1 + 10) * k, (cy + gap + 10) * k), fill=255),
))
out.paste(Image.new("RGBA", (TW, TH), color), (0, 0), arrows)

out.convert("RGB").save(dst)
print("tile", (TW, TH), "phone", (nw, nh), "folder at", fx0, "arrows", ax0, "->", ax1)
