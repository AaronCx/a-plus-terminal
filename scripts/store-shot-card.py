#!/usr/bin/env python3
"""Compose an App Store screenshot card: headline, accent rule, subtitle, device shot.

The seven original 1.0.3 screenshots were made outside this repo and no
generator survived, so the geometry below was measured back off the live
assets (shot-01-hero-real.png) rather than guessed:

    canvas      1320x2868
    background  vertical gradient #1A2230 -> #0D1117
    headline    SF Pro Bold ~96px, white, centred, up to two lines
    accent rule 180x8, #2DD4BF, centred, y=343
    subtitle    SF Pro Regular ~38px, #9FB0C3, centred, baseline band y=400
    device      1024px wide, top y=600, rounded corners, hairline border

Usage:
    store-shot-card.py OUT.png SHOT.png "Headline text" "Subtitle text"

Requires Pillow. The device screenshot is scaled to the frame width; any
source resolution works as long as it is a phone-shaped aspect.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

CANVAS = (1320, 2868)
BG_TOP = (26, 34, 48)
BG_BOTTOM = (13, 17, 23)
HEADLINE_RGB = (255, 255, 255)
ACCENT_RGB = (45, 212, 191)
SUBTITLE_RGB = (159, 176, 195)

HEADLINE_SIZE = 96
HEADLINE_INK_TOP = 141       # measured: ink (not ascender box) starts here
HEADLINE_LEADING = 97        # measured line-to-line advance
SUBTITLE_INK_TOP = 400       # measured
SUBTITLE_SIZE = 38
ACCENT_Y = 343
ACCENT_W, ACCENT_H = 180, 8
FRAME_TOP = 600
FRAME_W = 1024
FRAME_RADIUS = 52
BORDER_RGB = (58, 74, 94)

SF = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    f = ImageFont.truetype(SF, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass  # non-variable fallback: shape is close enough to keep going
    return f


def wrap(draw, text, fnt, max_width):
    """Greedy wrap to at most two lines — the template has room for no more."""
    words, lines, current = text.split(), [], ""
    for w in words:
        trial = f"{current} {w}".strip()
        if draw.textlength(trial, font=fnt) <= max_width or not current:
            current = trial
        else:
            lines.append(current)
            current = w
    if current:
        lines.append(current)
    return lines


def centred_ink(draw, text, fnt, ink_top, fill):
    """Place text so its *ink* starts at `ink_top`.

    PIL positions from the ascender box, which sits well above the visible
    glyphs — the first pass drew the headline low enough to collide with the
    accent rule. Measuring the bbox and correcting is what makes the output
    line up with the seven originals.
    """
    box = draw.textbbox((0, 0), text, font=fnt)
    draw.text(((CANVAS[0] - (box[2] - box[0])) / 2 - box[0], ink_top - box[1]),
              text, font=fnt, fill=fill)


def rounded_shot(shot, width, radius):
    """Scale the screenshot to `width` and round its corners."""
    height = round(shot.height * width / shot.width)
    shot = shot.convert("RGB").resize((width, height), Image.LANCZOS)
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, width - 1, height - 1], radius=radius, fill=255)
    out = Image.new("RGBA", (width, height))
    out.paste(shot, (0, 0))
    out.putalpha(mask)
    return out


def build(shot_path, headline, subtitle):
    canvas = Image.new("RGB", CANVAS, BG_TOP)
    draw = ImageDraw.Draw(canvas)

    # Vertical gradient, one row at a time.
    for y in range(CANVAS[1]):
        t = y / (CANVAS[1] - 1)
        draw.line(
            [(0, y), (CANVAS[0], y)],
            fill=tuple(round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)),
        )

    head_font = font(HEADLINE_SIZE, "Bold")
    lines = wrap(draw, headline, head_font, CANVAS[0] - 2 * 150)
    if len(lines) > 2:
        raise SystemExit(f"headline wraps to {len(lines)} lines; shorten it: {headline!r}")
    for i, line in enumerate(lines):
        centred_ink(draw, line, head_font, HEADLINE_INK_TOP + i * HEADLINE_LEADING, HEADLINE_RGB)

    # Accent rule sits at a fixed y in the original, under a two-line headline.
    accent_y = ACCENT_Y - (HEADLINE_LEADING if len(lines) == 1 else 0)
    x0 = (CANVAS[0] - ACCENT_W) / 2
    draw.rounded_rectangle(
        [x0, accent_y, x0 + ACCENT_W, accent_y + ACCENT_H], radius=ACCENT_H / 2, fill=ACCENT_RGB
    )

    sub_font = font(SUBTITLE_SIZE, "Regular")
    sub_lines = wrap(draw, subtitle, sub_font, CANVAS[0] - 2 * 130)
    if len(sub_lines) > 1:
        raise SystemExit(
            f"subtitle wraps to {len(sub_lines)} lines; the originals are all one line: {subtitle!r}")
    sub_top = SUBTITLE_INK_TOP - (HEADLINE_LEADING if len(lines) == 1 else 0)
    centred_ink(draw, sub_lines[0], sub_font, sub_top, SUBTITLE_RGB)

    device = rounded_shot(Image.open(shot_path), FRAME_W, FRAME_RADIUS)
    x = (CANVAS[0] - FRAME_W) // 2
    # Hairline border, drawn under the shot so the corners stay clean.
    ImageDraw.Draw(canvas).rounded_rectangle(
        [x - 2, FRAME_TOP - 2, x + FRAME_W + 1, FRAME_TOP + device.height + 1],
        radius=FRAME_RADIUS + 2, outline=BORDER_RGB, width=2,
    )
    canvas.paste(device, (x, FRAME_TOP), device)
    return canvas


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    out, shot, headline, subtitle = sys.argv[1:5]
    build(shot, headline, subtitle).save(out)
    print(f"wrote {out}")
