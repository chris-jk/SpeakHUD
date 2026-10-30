#!/usr/bin/env python3
"""Draws the phone page's home screen icon -> phone/icon.png: the four sessions of
Agent Terminal's icon, full bleed because iOS rounds the corners itself.

  uv run --with pillow python phone/make-icon.py
"""
from PIL import Image, ImageDraw

S = 1024
PANES = [(0x8c, 0x5c, 0xd9), (0x40, 0xad, 0x66), (0xd9, 0x4d, 0x4d), (0x4d, 0x80, 0xe6)]
PINK = (0xff, 0x2d, 0x78)

img = Image.new('RGB', (S, S), (14, 14, 18))
d = ImageDraw.Draw(img)
gap, left, top, size = 44, 112, 112, 378
for i, color in enumerate(PANES):
    x = left + (i % 2) * (size + gap)
    y = top + (i // 2) * (size + gap)
    d.rounded_rectangle((x, y, x + size, y + size), radius=40, fill=(32, 32, 38))
    d.rounded_rectangle((x, y, x + size, y + 72), radius=32, fill=color)
    d.rectangle((x, y + 40, x + size, y + 72), fill=color)
    for row, width in enumerate((230, 160)):
        d.rectangle((x + 40, y + 118 + row * 66, x + 40 + width, y + 148 + row * 66), fill=(150, 150, 160))
    if i == 3:
        d.rectangle((x + 40, y + 252, x + 100, y + 330), fill=PINK)
img.resize((512, 512), Image.LANCZOS).save('phone/icon.png', optimize=True)
