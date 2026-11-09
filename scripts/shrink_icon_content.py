# Shrinks the phone inside the white "My Files" icon so it has comfortable padding.
# usage: shrink_icon_content.py src.png out.png [scale]
import sys
from PIL import Image, ImageDraw, ImageFilter
src, dst = sys.argv[1], sys.argv[2]
scale = float(sys.argv[3]) if len(sys.argv) > 3 else 0.74
im = Image.open(src).convert("RGB")
TILE = (74, 62, 1178, 1175)            # white rounded square in the source
PHONE = (352, 112, 912, 1135)          # phone + its shadow
tile = im.crop(TILE)
tw, th = tile.size

# Clean background: sample the tile's own white so the seam is invisible.
samples = [tile.getpixel(p) for p in [(120, th // 2), (tw - 120, th // 2), (tw // 2, 30), (160, 160), (tw - 160, th - 160)]]
bg = tuple(sum(c[i] for c in samples) // len(samples) for i in range(3))
out = Image.new("RGB", (tw, th), bg)

phone = im.crop(PHONE)
pw, ph = phone.size
# feathered mask so the shadow fades into the new background
m = Image.new("L", (pw, ph), 0)
f = 22
ImageDraw.Draw(m).rectangle((f, f, pw - f, ph - f), fill=255)
m = m.filter(ImageFilter.GaussianBlur(f / 2))
nw, nh = int(pw * scale), int(ph * scale)
phone = phone.resize((nw, nh), Image.LANCZOS)
m = m.resize((nw, nh), Image.LANCZOS)
out.paste(phone, ((tw - nw) // 2, (th - nh) // 2 + 4), m)
out.save(dst)
print("bg", bg, "phone", (nw, nh), "tile", (tw, th), f"phone height = {nh/th:.0%} of tile")
