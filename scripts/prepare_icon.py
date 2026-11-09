# Cleans an AI-generated icon: crops to the solid squircle, applies a smooth
# rounded mask (removes fringe), and places it on Apple's 1024px icon grid.
import sys
from PIL import Image, ImageDraw, ImageFilter
src, dst = sys.argv[1], sys.argv[2]
raw = Image.open(src)
im = raw.convert("RGBA")
a = im.getchannel("A")
if len(sys.argv) > 3:
    # manual crop box "left,top,right,bottom" (for white-on-white images)
    l, t, r, b = map(int, sys.argv[3].split(","))
elif a.getextrema()[0] < 200:
    # real transparency: bounding box of solid pixels only (ignore soft halo)
    solid = a.point(lambda v: 255 if v > 230 else 0)
    l, t, r, b = solid.getbbox()
else:
    # no transparency (e.g. a fake checkerboard is painted in): find the coloured
    # icon body by saturation — the grey checkerboard has none.
    w, h = im.size
    px = im.load()
    def colourful(x, y):
        R, G, B, _ = px[x, y]
        return max(R, G, B) - min(R, G, B) > 60
    def rowhit(y): return sum(colourful(x, y) for x in range(0, w, 2)) > w * 0.25
    def colhit(x): return sum(colourful(x, y) for y in range(0, h, 2)) > h * 0.25
    ys = [y for y in range(h) if rowhit(y)]
    xs = [x for x in range(w) if colhit(x)]
    l, t, r, b = xs[0], ys[0], xs[-1] + 1, ys[-1] + 1
# shrink a little to cut the ragged edge
inset = int((r - l) * 0.012) if len(sys.argv) <= 3 else 2
box = (l + inset, t + inset, r - inset, b - inset)
im = im.crop(box)
S = 824  # Apple macOS icon body size on a 1024 canvas
im = im.resize((S, S), Image.LANCZOS)
# smooth squircle-ish mask, drawn at 4x for anti-aliasing
k = 4
m = Image.new("L", (S * k, S * k), 0)
ImageDraw.Draw(m).rounded_rectangle((0, 0, S * k - 1, S * k - 1), radius=int(S * k * 0.225), fill=255)
m = m.resize((S, S), Image.LANCZOS)
im.putalpha(m)
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
# soft drop shadow like system icons
shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
sh = Image.new("RGBA", (S, S), (0, 0, 0, 90)); sh.putalpha(m.point(lambda v: v * 90 // 255))
shadow.paste(sh, (100, 112), sh)
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
canvas.alpha_composite(shadow)
canvas.alpha_composite(im, (100, 100))
canvas.save(dst)
print("saved", dst, "box", box)
