"""Build AIUsageWidget icons + Teknic company logo derivatives.

Requires assets/company-logo-src.png (full teknic.cc lockup).
Run: python assets/make_icon.py [output_dir]
"""
from __future__ import annotations

import math
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else HERE
SRC = os.path.join(HERE, "company-logo-src.png")

CYAN = (38, 200, 254, 255)
CYAN_DIM = (38, 200, 254, 150)
CARD = (17, 24, 39, 255)
GOOD = (61, 220, 132, 255)
WARN = (255, 179, 0, 255)
MUTED = (107, 114, 128, 255)


def knock_dark(img: Image.Image) -> Image.Image:
    out = img.convert("RGBA")
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            lum = (r + g + b) / 3
            if a < 20 or lum < 28:
                px[x, y] = (0, 0, 0, 0)
            elif lum < 55 and abs(r - g) < 12 and abs(g - b) < 12:
                px[x, y] = (0, 0, 0, 0)
    return out


def trim(img: Image.Image) -> Image.Image:
    bbox = img.getbbox()
    return img.crop(bbox) if bbox else img


def build_logos(src: Image.Image) -> tuple[Image.Image, Image.Image]:
    wordmark = trim(knock_dark(src))
    # Left monogram only (circle + TK); wordmark "tek..." starts ~x=110.
    glyph = trim(knock_dark(src.crop((12, 0, 96, src.height))))
    # Rebuild the circular badge so the grey ring survives dark knockout.
    side = max(glyph.width, glyph.height) + 28
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    d = ImageDraw.Draw(sq)
    inset = 3
    d.ellipse((inset, inset, side - 1 - inset, side - 1 - inset), outline=CYAN, width=4)
    sq.paste(
        glyph,
        ((side - glyph.width) // 2, (side - glyph.height) // 2),
        glyph,
    )
    return wordmark, sq


def draw_app_icon(mark: Image.Image, size: int = 1024) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = 48
    d.rounded_rectangle((pad, pad, size - pad, size - pad), radius=220, fill=CARD)
    d.rounded_rectangle((pad, pad, size - pad, size - pad), radius=220, outline=CYAN, width=18)

    cx, cy = size // 2 - 36, size // 2 + 8
    arc = (cx - 290, cy - 290, cx + 290, cy + 290)
    d.arc(arc, start=200, end=340, fill=MUTED, width=40)
    d.arc(arc, start=200, end=305, fill=CYAN, width=40)
    tip = (int(cx + 248), int(cy - 148))
    d.ellipse((tip[0] - 30, tip[1] - 30, tip[0] + 30, tip[1] + 30), fill=CYAN)

    bars = [0.38, 0.55, 0.72, 0.92]
    colors = [CYAN_DIM, CYAN, GOOD, WARN]
    base_x, base_y = 230, 730
    bw, gap = 82, 34
    for i, hfrac in enumerate(bars):
        h = int(300 * hfrac)
        x0 = base_x + i * (bw + gap)
        y0 = base_y - h
        d.rounded_rectangle((x0, y0, x0 + bw, base_y), radius=30, fill=colors[i])

    badge = mark.resize((280, 280), Image.LANCZOS)
    bx, by = size - pad - 300, size - pad - 300
    d.ellipse((bx - 8, by - 8, bx + 288, by + 288), fill=(8, 12, 22, 235))
    img.paste(badge, (bx, by), badge)
    return img


def draw_tray(size: int = 32) -> Image.Image:
    """32px tray: AIUsageWidget motif (cyan rim + 4 meter bars), not the Teknic mark."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((1, 1, size - 2, size - 2), radius=7, fill=CARD, outline=CYAN, width=2)
    # Ascending usage bars - readable at tray size.
    bars = [0.40, 0.58, 0.75, 0.95]
    colors = [CYAN_DIM, CYAN, GOOD, WARN]
    base_y = size - 6
    left, gap = 5, 2
    bw = max(3, (size - 2 * left - 3 * gap) // 4)
    for i, hfrac in enumerate(bars):
        h = max(3, int((size - 12) * hfrac))
        x0 = left + i * (bw + gap)
        d.rounded_rectangle((x0, base_y - h, x0 + bw, base_y), radius=1, fill=colors[i])
    return img


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    if not os.path.isfile(SRC):
        raise SystemExit(f"missing source logo: {SRC}")
    src = Image.open(SRC).convert("RGBA")
    wordmark, mark = build_logos(src)

    wordmark.save(os.path.join(OUT, "company-logo.png"))
    mark.save(os.path.join(OUT, "company-mark.png"))
    h = 56
    w = max(1, int(wordmark.width * (h / wordmark.height)))
    wordmark.resize((w, h), Image.LANCZOS).save(os.path.join(OUT, "company-logo-header.png"))

    big = draw_app_icon(mark, 1024)
    sizes = [16, 24, 32, 48, 64, 128, 256]
    big.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT, "icon.png"))
    big.save(os.path.join(OUT, "icon.ico"), sizes=[(s, s) for s in sizes])
    big.save(os.path.join(OUT, "icon-1024.png"))

    tray = draw_tray(32)
    tray.save(os.path.join(OUT, "tray32.png"))
    with open(os.path.join(OUT, "tray32.rgba"), "wb") as f:
        f.write(tray.tobytes())
    print("ok")


if __name__ == "__main__":
    main()
