# White tile + glossy Telegram-blue folder (paper sheet peeking out) + white paper plane.
# usage: folder_style_icon.py out_tile.png
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
    m = Image.new("L", (S * K, S * K), 0)
    fn(ImageDraw.Draw(m), K)
    if round_px:
        m = m.filter(ImageFilter.GaussianBlur(round_px * K)).point(lambda v: 255 if v > 127 else 0)
    return m.resize((S, S), Image.LANCZOS)

def shadow(m, color, alpha, blur, dy):
    sh = Image.new("RGBA", (S, S), color + (0,))
    sh.putalpha(m.point(lambda v: v * alpha // 255))
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0)); layer.alpha_composite(sh, (0, dy))
    return layer

out = vgrad((255, 255, 255), (243, 244, 247))

# ---- folder geometry ----
W, H = int(S * 0.78), int(S * 0.61)
x0 = (S - W) // 2
y0 = (S - H) // 2 + 10
x1, y1 = x0 + W, y0 + H
R = int(S * 0.055)
tab_w, tab_h = int(W * 0.40), int(S * 0.075)
front_top = y0 + tab_h + int(H * 0.14)

back = mask(lambda d, k: (
    d.rounded_rectangle((x0*k, y0*k, (x0 + tab_w)*k, (y0 + tab_h + R*2)*k), radius=R*0.8*k, fill=255),
    d.polygon([((x0 + tab_w - 40)*k, y0*k), ((x0 + tab_w + 40)*k, (y0 + tab_h)*k), ((x0 + tab_w - 40)*k, (y0 + tab_h)*k)], fill=255),
    d.rounded_rectangle((x0*k, (y0 + tab_h)*k, x1*k, y1*k), radius=R*k, fill=255),
), round_px=8)
paper = mask(lambda d, k: d.rounded_rectangle(((x0 + W*0.06)*k, (y0 + tab_h + H*0.05)*k, (x1 - W*0.06)*k, (front_top + 60)*k), radius=R*0.5*k, fill=255))
front = mask(lambda d, k: d.rounded_rectangle((x0*k, front_top*k, x1*k, y1*k), radius=R*k, fill=255))

out.alpha_composite(shadow(back, (0, 70, 140), 80, 28, 24))
out.paste(vgrad((30, 141, 208), (22, 120, 186), y0, y1), (0, 0), back)
out.alpha_composite(shadow(paper, (0, 60, 120), 70, 6, 4))
out.paste(vgrad((255, 255, 255), (236, 238, 242), y0, front_top), (0, 0), paper)
out.alpha_composite(shadow(front, (0, 60, 130), 90, 10, -4))
out.paste(vgrad((66, 186, 240), (34, 158, 217), front_top, y1), (0, 0), front)
# glossy top edge on the front panel
gloss = mask(lambda d, k: d.rounded_rectangle(((x0 + R*0.6)*k, (front_top + 4)*k, (x1 - R*0.6)*k, (front_top + 12)*k), radius=4*k, fill=255))
out.paste(Image.new("RGBA", (S, S), (160, 222, 252, 255)), (0, 0), gloss)

# ---- white paper plane on the front panel (shape from assets/PlaneGlyph.png) ----
import os
glyph = Image.open(os.path.join(os.path.dirname(__file__), "..", "assets", "PlaneGlyph.png")).convert("L")
panel_h = y1 - front_top
gh = int(panel_h * 0.66)                       # plane height
gw = int(glyph.width * gh / glyph.height)
glyph = glyph.resize((gw, gh), Image.LANCZOS)
gx = S // 2 - gw // 2 - int(gw * 0.03)         # optical centring (plane points up-right)
gy = front_top + (panel_h - gh) // 2 + int(gh * 0.03)
plane = Image.new("L", (S, S), 0); plane.paste(glyph, (gx, gy))

out.alpha_composite(shadow(plane, (0, 80, 150), 120, 9, 8))
out.paste(Image.new("RGBA", (S, S), (255, 255, 255, 255)), (0, 0), plane)

out.convert("RGB").save(sys.argv[1])
print("saved", sys.argv[1])
