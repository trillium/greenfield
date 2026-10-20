"""Regenerates the app icon (1024x1024 PNG, RGB, no alpha). Needs Pillow:
    uv run --with pillow python3 tools/icon/make_icon.py
Writes App/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png. The icon is drawn in code so it is original and reproducible."""
import math, os
from PIL import Image, ImageDraw

SS = 4          # supersampling factor
SIZE = 1024     # final icon size


def canvas():
    return Image.new("RGB", (SIZE * SS, SIZE * SS), (0, 0, 0))


def gradient(img, top, bottom, angle_deg=90):
    """Linear gradient from `top` to `bottom` along an angle (90 = top to bottom)."""
    w, h = img.size
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    px = img.load()
    # project every pixel on the gradient axis
    lo = min(0 * dx + 0 * dy, w * dx + 0 * dy, 0 * dx + h * dy, w * dx + h * dy)
    hi = max(0 * dx + 0 * dy, w * dx + 0 * dy, 0 * dx + h * dy, w * dx + h * dy)
    for y in range(h):
        for x in range(0, w, 1):
            t = ((x * dx + y * dy) - lo) / (hi - lo)
            px[x, y] = (
                int(top[0] + (bottom[0] - top[0]) * t),
                int(top[1] + (bottom[1] - top[1]) * t),
                int(top[2] + (bottom[2] - top[2]) * t),
            )
    return img


def fast_gradient(img, top, bottom, angle_deg=90):
    """Same result as `gradient`, built from a small image and resized (much faster at 4096px)."""
    n = 256
    small = Image.new("RGB", (n, n))
    gradient(small, top, bottom, angle_deg)
    return small.resize(img.size, Image.BICUBIC)


def s(v):
    """Scale a coordinate given on the 1024 grid to the supersampled canvas."""
    return v * SS


def finish(img, path):
    out = img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")  # RGB: no alpha channel, as the App Store requires
    out.save(path, "PNG", optimize=True)
    return out


WHITE = (255, 255, 255)


def line(d, p0, p1, w, fill):
    d.line([(s(p0[0]), s(p0[1])), (s(p1[0]), s(p1[1]))], fill=fill, width=s(w))
    r = w / 2
    for x, y in (p0, p1):
        d.ellipse([s(x - r), s(y - r), s(x + r), s(y + r)], fill=fill)


def arc(d, cx, cy, radius, a0, a1, w, fill):
    d.arc([s(cx - radius), s(cy - radius), s(cx + radius), s(cy + radius)], a0, a1, fill=fill, width=s(w))
    r = w / 2
    for a in (a0, a1):
        x = cx + radius * math.cos(math.radians(a))
        y = cy + radius * math.sin(math.radians(a))
        d.ellipse([s(x - r), s(y - r), s(x + r), s(y + r)], fill=fill)


def rrect(d, box, radius, fill):
    d.rounded_rectangle([s(box[0]), s(box[1]), s(box[2]), s(box[3])], radius=s(radius), fill=fill)


def circle(d, cx, cy, r, fill):
    d.ellipse([s(cx - r), s(cy - r), s(cx + r), s(cy + r)], fill=fill)


def blend(c0, c1, t):
    return tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3))


def dictation():
    """Speech becoming text: a white speech bubble holding a cyan-to-lime waveform, on night blue to graphite."""
    top, bottom = (14, 22, 52), (44, 62, 74)
    img = fast_gradient(canvas(), top, bottom, 70)
    d = ImageDraw.Draw(img)
    rrect(d, (136, 190, 888, 690), 150, WHITE)
    d.polygon([(s(238), s(660)), (s(238), s(852)), (s(440), s(676))], fill=WHITE)  # the bubble's tail
    cyan, lime = (0, 190, 230), (150, 220, 40)
    heights = (70, 150, 250, 330, 250, 150, 70)
    for i, h in enumerate(heights):
        x = 232 + i * 93
        line(d, (x, 440 - h / 2), (x, 440 + h / 2), 46, blend(cyan, lime, i / (len(heights) - 1)))
    return img


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out = os.path.join(root, "App/Sources/Assets.xcassets/AppIcon.appiconset", "AppIcon-1024.png")
    finish(dictation(), out)
    print("wrote", out)
