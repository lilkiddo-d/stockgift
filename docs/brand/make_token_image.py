"""Renders the $GIFT token image (docs/brand/gift-token.png, 1024x1024, transparent corners)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersampling
N = 1024 * S
OUT = Path(__file__).with_name("gift-token.png")

GREEN_DARK = (11, 61, 38)
GREEN = (31, 164, 99)
GOLD = (255, 200, 70)
GOLD_DARK = (214, 150, 20)
WHITE = (255, 255, 255)


def s(v):
    return int(v * S)


img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

# radial-ish gradient disc
grad = Image.new("RGBA", (N, N))
gd = ImageDraw.Draw(grad)
for i in range(N):
    t = i / N
    c = tuple(int(GREEN[k] * (1 - t) + GREEN_DARK[k] * t) for k in range(3))
    gd.line([(0, i), (N, i)], fill=c + (255,))
mask = Image.new("L", (N, N), 0)
ImageDraw.Draw(mask).ellipse([s(16), s(16), N - s(16), N - s(16)], fill=255)
img.paste(grad, (0, 0), mask)

d = ImageDraw.Draw(img)
# inner ring
d.ellipse([s(52), s(52), N - s(52), N - s(52)], outline=(255, 255, 255, 60), width=s(10))

# soft shadow under the box
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([s(262), s(470), s(762), s(842)], radius=s(36), fill=(0, 0, 0, 90))
img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(s(18))))
d = ImageDraw.Draw(img)

# gift box: body + lid
d.rounded_rectangle([s(272), s(470), s(752), s(812)], radius=s(30), fill=WHITE)
d.rounded_rectangle([s(240), s(392), s(784), s(488)], radius=s(26), fill=WHITE)
d.line([(s(250), s(488)), (s(774), s(488))], fill=(220, 228, 222), width=s(6))
# ribbon
d.rectangle([s(476), s(392), s(548), s(812)], fill=GOLD)
d.rectangle([s(476), s(392), s(548), s(488)], fill=GOLD_DARK)

# bow (two loops + knot)
d.ellipse([s(352), s(268), s(512), s(404)], outline=GOLD, width=s(34))
d.ellipse([s(512), s(268), s(672), s(404)], outline=GOLD, width=s(34))
d.rounded_rectangle([s(470), s(348), s(554), s(408)], radius=s(18), fill=GOLD_DARK)

# rising chart arrow across the box face
pts = [(s(318), s(742)), (s(428), s(652)), (s(520), s(700)), (s(690), s(548))]
d.line(pts, fill=GREEN, width=s(40), joint="curve")
for x, y in pts[:-1]:
    d.ellipse([x - s(20), y - s(20), x + s(20), y + s(20)], fill=GREEN)
# arrow head
hx, hy = pts[-1]
d.polygon([(hx + s(38), hy - s(34)), (hx - s(50), hy - s(22)), (hx + s(22), hy + s(52))], fill=GREEN)

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
img.resize((256, 256), Image.LANCZOS).save(OUT.with_name("gift-token-256.png"))
print("wrote", OUT)
