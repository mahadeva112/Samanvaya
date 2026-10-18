"""Draws the Samanvaya icon: a teal VO wave and an amber dub wave that start
out of phase and lock in sync, on the panel's dark card. Colours are the panel's
own (SUI.col in Samanvaya.lua).

    py -3.12 installer/make_icon.py        (needs Pillow)

Writes, next to this file:
    Samanvaya.ico          setup exe, uninstaller, Apps & Features
    Samanvaya.png          1024 px master, for GitHub / docs
    wizard_small*.bmp      top-right corner of the setup wizard pages
    wizard_large*.bmp      left panel of the Welcome / Finish pages
"""
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
S = 1024                         # master canvas

TEAL  = (0x38, 0xC9, 0xB0)
AMBER = (0xF0, 0xA2, 0x4B)
TOP   = (0x1F, 0x24, 0x2F)       # a touch above cardhi, so the tile lifts
BOT   = (0x0A, 0x0C, 0x10)       # well
RIM   = (255, 255, 255, 34)


def _vgrad(w, h, c0, c1):
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(c0, c1)))
    return g.resize((w, h))


def _waves():
    """Teal (VO) and amber (dub) are the same wave, out of phase at the left
    and drifting into phase until they lock about two thirds of the way
    across: that is what a sync does."""
    x0, x1 = 186, 838
    amp, cycles = 150, 1.5
    teal, amber = [], []
    for i in range(601):
        t = i / 600
        x = x0 + (x1 - x0) * t
        w = 2 * math.pi * cycles * t + 0.5
        phi = 2.1 * max(0.0, 1 - t / 0.7) ** 2
        env = 0.75 + 0.25 * t
        # Once locked they run as a two-tone ribbon, a hair apart, so both
        # lanes stay visible instead of amber hiding teal.
        teal.append((x, -amp * env * math.sin(w + phi) - 21))
        amber.append((x, -amp * env * math.sin(w - phi) + 21))
    ys = [y for _, y in teal + amber]
    off = S / 2 - (min(ys) + max(ys)) / 2
    return ([(x, y + off) for x, y in teal], [(x, y + off) for x, y in amber])


def _stroke(layer, pts, colour, width):
    """Stamp discs along the path on a 2x canvas: PIL's wide polylines leave
    ragged joints, discs give a clean round-capped stroke."""
    big = Image.new("L", (S * 2, S * 2), 0)
    d = ImageDraw.Draw(big)
    r = width  # radius at 2x == width/2 at 1x
    for (xa, ya), (xb, yb) in zip(pts, pts[1:]):
        n = max(1, int(math.hypot(xb - xa, yb - ya)))
        for k in range(n):
            x = (xa + (xb - xa) * k / n) * 2
            y = (ya + (yb - ya) * k / n) * 2
            d.ellipse((x - r, y - r, x + r, y + r), fill=255)
    x, y = pts[-1][0] * 2, pts[-1][1] * 2
    d.ellipse((x - r, y - r, x + r, y + r), fill=255)
    alpha = big.resize((S, S), Image.LANCZOS).point(lambda a: a * colour[3] // 255)
    solid = Image.new("RGBA", (S, S), colour[:3] + (0,))
    solid.putalpha(alpha)
    layer.alpha_composite(solid)


def render(bold=False):
    """bold=True thickens the strokes for the 16-32 px sizes."""
    width = 84 if bold else 48
    tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 0)
    margin, radius = 40, 230
    ImageDraw.Draw(mask).rounded_rectangle((margin, margin, S - margin, S - margin), radius, fill=255)
    tile.paste(_vgrad(S, S, TOP, BOT), (0, 0), mask)

    waves = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    teal_pts, amber_pts = _waves()
    _stroke(waves, teal_pts, TEAL + (255,), width)
    _stroke(waves, amber_pts, AMBER + (255,), width)

    # Soft glow under the strokes.
    glow = waves.filter(ImageFilter.GaussianBlur(38))
    glow.putalpha(glow.getchannel("A").point(lambda a: int(a * 0.55)))
    tile.alpha_composite(glow)
    tile.alpha_composite(waves)

    # The sync point: where both lanes end as one.
    ex = amber_pts[-1][0]
    ey = (amber_pts[-1][1] + teal_pts[-1][1]) / 2
    r = width * 0.85
    halo = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse((ex - r * 2.2, ey - r * 2.2, ex + r * 2.2, ey + r * 2.2), fill=(255, 236, 200, 150))
    tile.alpha_composite(halo.filter(ImageFilter.GaussianBlur(30)))
    ImageDraw.Draw(tile).ellipse((ex - r, ey - r, ex + r, ey + r), fill=(255, 248, 236, 255))

    # Keep glow inside the tile, then add a hairline rim.
    tile.putalpha(ImageChops.multiply(tile.getchannel("A"), mask))
    ImageDraw.Draw(tile).rounded_rectangle((margin, margin, S - margin, S - margin), radius, outline=RIM, width=6)
    return tile


def _bmp(img, w, h, bg):
    """Wizard bitmaps have no alpha: flatten the icon onto the wizard ground."""
    canvas = Image.new("RGB", (w, h), bg)
    side = min(w, h)
    icon = img.resize((side, side), Image.LANCZOS)
    canvas.paste(icon, ((w - side) // 2, (h - side) // 2), icon)
    return canvas


def main():
    big, bold = render(), render(bold=True)
    big.save(HERE / "Samanvaya.png")

    frames = [(bold if s <= 32 else big).resize((s, s), Image.LANCZOS)
              for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)]
    frames[-1].save(HERE / "Samanvaya.ico", format="ICO",
                    sizes=[f.size for f in frames], append_images=frames[:-1])

    # Inno picks the best fit from a comma list, so supply 100%-250% DPI.
    white = (255, 255, 255)
    for scale, tag in ((1, ""), (1.5, "_150"), (2, "_200"), (2.5, "_250")):
        _bmp(big, round(55 * scale), round(55 * scale), white).save(HERE / f"wizard_small{tag}.bmp")
        large = Image.new("RGB", (round(164 * scale), round(314 * scale)), BOT)
        large.paste(_vgrad(*large.size, TOP, BOT))
        side = round(124 * scale)
        icon = big.resize((side, side), Image.LANCZOS)
        large.paste(icon, ((large.width - side) // 2, round(70 * scale)), icon)
        large.save(HERE / f"wizard_large{tag}.bmp")
    print("icon written to", HERE)


if __name__ == "__main__":
    main()
