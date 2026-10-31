#!/usr/bin/env python3
"""rain_glyphs.py [PREVIEW.png]: the letters of frame's falling-code beam-in.

Prints the `rain_glyphs` table for frame.asm: 32 letters (half-width
katakana and digits, mirrored as in the film), each 16 rows of 12 pixels,
one word per row, bit 0 the leftmost pixel. With a file name it also
draws the 32 letters there, large, to judge them. Needs Pillow.
"""
import sys

from PIL import Image, ImageDraw, ImageFont

LETTERS = "ﾊﾐﾋｰｳｼﾅﾓﾆｻﾜﾂｵﾘｱﾎﾃﾏｹﾒｴｶｷﾑﾕﾗｾ" + "01579"
KANA = ImageFont.truetype("/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf", 17)
MONO = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 14)
W, H = 12, 16


def bitmap(ch):
    big = Image.new("L", (3 * W, 3 * H))
    font = MONO if ch.isdigit() else KANA
    ImageDraw.Draw(big).text((1.5 * W, 1.5 * H), ch, font=font, fill=255, anchor="mm")
    letter = big.crop(big.getbbox())  # centred by its own outline
    img = Image.new("L", (W, H))
    img.paste(letter, ((W - letter.width) // 2, (H - letter.height) // 2))
    img = img.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    return [[img.getpixel((x, y)) > 110 for x in range(W)] for y in range(H)]


assert len(LETTERS) == 32
maps = [bitmap(c) for c in LETTERS]
for ch, m in zip(LETTERS, maps):
    words = [sum(1 << x for x in range(W) if row[x]) for row in m]
    print(f"    dw {', '.join(f'0x{w:03X}' for w in words)}   ; {ch}")
if len(sys.argv) > 1:
    big = Image.new("RGB", (32 * 14 * 4, 18 * 4))
    d = ImageDraw.Draw(big)
    for i, m in enumerate(maps):
        for y in range(H):
            for x in range(W):
                if m[y][x]:
                    d.rectangle([(i * 14 + x) * 4, y * 4 + 4, (i * 14 + x) * 4 + 3, y * 4 + 7], fill=(0, 255, 65))
    big.save(sys.argv[1])
