#!/usr/bin/env python3
"""Renders Gauge's app icon (1024 px master). Requires Pillow. Font: Geist Mono (SIL OFL)."""
import sys, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops
HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.environ.get("GAUGE_ICON_FONT", os.path.join(HERE, "GeistMono.ttf"))  # Geist Mono variable TTF (OFL), not committed
S = 4                        # supersample
W = 1024 * S
def px(v): return int(v * S)

def squircle_mask(size, box, n=5.0):
    """Superellipse mask (Apple-like continuous corners)."""
    import math
    x0, y0, x1, y1 = box
    cx, cy, a, b = (x0+x1)/2, (y0+y1)/2, (x1-x0)/2, (y1-y0)/2
    pts = []
    for i in range(2000):
        t = 2*math.pi*i/2000
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + a*(abs(c)**(2/n))*(1 if c>=0 else -1), cy + b*(abs(s)**(2/n))*(1 if s>=0 else -1)))
    m = Image.new("L", size, 0); ImageDraw.Draw(m).polygon(pts, fill=255); return m

def vgrad(size, top, bot):
    w, h = size
    g = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y/(h-1); g.putpixel((0, y), tuple(int(top[i]+(bot[i]-top[i])*t) for i in range(4)))
    return g.resize(size)

def rrect(size, box, r, fill):
    im = Image.new("RGBA", size, (0,0,0,0)); ImageDraw.Draw(im).rounded_rectangle(box, r, fill=fill); return im

img = Image.new("RGBA", (W, W), (0,0,0,0))
box = (px(100), px(100), px(924), px(924))       # Big Sur grid: 824 px body
mask = Image.new("L", (W, W), 0); ImageDraw.Draw(mask).rounded_rectangle(box, px(186), fill=255)

# drop shadow
sh = Image.new("RGBA", (W, W), (0,0,0,0))
_m = Image.new("L", (W, W), 0); ImageDraw.Draw(_m).rounded_rectangle((box[0], box[1]+px(12), box[2], box[3]+px(12)), px(186), fill=255)
sh.putalpha(_m.point(lambda v: int(v*0.40)))
img = Image.alpha_composite(img, sh.filter(ImageFilter.GaussianBlur(px(18))))

# body: graphite gradient
body = vgrad((W, W), (52, 55, 62, 255), (16, 17, 21, 255))
# soft radial glow of the accent from below
glow = Image.new("RGBA", (W, W), (0,0,0,0))
ImageDraw.Draw(glow).ellipse((px(180), px(560), px(844), px(1060)), fill=(10, 132, 255, 55))
body = Image.alpha_composite(body, glow.filter(ImageFilter.GaussianBlur(px(110))))
# glass sheen on upper half
sheen = vgrad((W, W), (255,255,255,34), (255,255,255,0))
sheen.putalpha(ImageChops.multiply(sheen.getchannel("A"), Image.new("L",(W,W),0).point(lambda v:0)) if False else sheen.getchannel("A"))
sm = Image.new("L", (W, W), 0); ImageDraw.Draw(sm).ellipse((px(-200), px(-560), px(1224), px(470)), fill=255)
sheen.putalpha(ImageChops.multiply(sheen.getchannel("A"), sm.filter(ImageFilter.GaussianBlur(px(120)))))
body = Image.alpha_composite(body, sheen)

layer = Image.new("RGBA", (W, W), (0,0,0,0))
layer.paste(body, (0, 0), mask)
img = Image.alpha_composite(img, layer)

# hairline rim (inner highlight top, darker bottom)
rim = Image.new("RGBA", (W, W), (255,255,255,0))
inner = Image.new("L", (W, W), 0); ImageDraw.Draw(inner).rounded_rectangle((box[0]+px(3), box[1]+px(3), box[2]-px(3), box[3]-px(3)), px(183), fill=255)
ring = ImageChops.subtract(mask, inner)
rimcol = vgrad((W, W), (255,255,255,90), (255,255,255,12))
rimcol.putalpha(ImageChops.multiply(rimcol.getchannel("A"), ring))
img = Image.alpha_composite(img, rimcol)

d = ImageDraw.Draw(img)
font = ImageFont.truetype(FONT, px(280))
try: font.set_variation_by_axes([600])
except Exception: pass
small = ImageFont.truetype(FONT, px(120))
try: small.set_variation_by_axes([400])
except Exception: pass

# percent: "63" big + "%" dimmer, left aligned on the card grid
x0, base = px(190), px(545)
d.text((x0, base), "63", font=font, fill=(244, 245, 247, 255), anchor="ls")
wnum = d.textlength("63", font=font)
d.text((x0 + wnum + px(14), base), "%", font=small, fill=(154, 156, 163, 255), anchor="ls")

# usage bar: track + accent fill draining (63%) with soft glow
bx0, bx1, by, bh = px(196), px(828), px(640), px(64)
track = rrect((W, W), (bx0, by, bx1, by+bh), bh//2, (255,255,255,30))
img = Image.alpha_composite(img, track)
fx1 = bx0 + int((bx1-bx0)*0.63)
fglow = rrect((W, W), (bx0, by, fx1, by+bh), bh//2, (10,132,255,170)).filter(ImageFilter.GaussianBlur(px(22)))
img = Image.alpha_composite(img, fglow)
fill = vgrad((W, W), (64, 160, 255, 255), (0, 110, 240, 255))
fm = Image.new("L", (W, W), 0); ImageDraw.Draw(fm).rounded_rectangle((bx0, by, fx1, by+bh), bh//2, fill=255)
fl = Image.new("RGBA", (W, W), (0,0,0,0)); fl.paste(fill, (0,0), fm)
img = Image.alpha_composite(img, fl)
hl = rrect((W, W), (bx0+px(10), by+px(7), fx1-px(10), by+px(20)), px(7), (255,255,255,70))
img = Image.alpha_composite(img, hl)

out = img.resize((1024, 1024), Image.LANCZOS)
out.save(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "AppIcon-1024.png"))
