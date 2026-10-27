#!/usr/bin/env python3
"""Gera o AppIcon (arte própria, procedural) em App/OptiStats/Resources/Assets.xcassets."""
import json, pathlib
from PIL import Image, ImageDraw
root = pathlib.Path(__file__).resolve().parent.parent / "App/OptiStats/Resources/Assets.xcassets"
icon = root / "AppIcon.appiconset"; icon.mkdir(parents=True, exist_ok=True)
(root / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))
def draw(px):
    S = 1024; im = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    d.rounded_rectangle((100, 100, 924, 924), radius=185, fill=(24, 30, 46, 255))
    bars = [0.35, 0.6, 0.45, 0.85, 0.7]
    for i, v in enumerate(bars):
        x = 220 + i * 120; h = int(560 * v)
        d.rounded_rectangle((x, 800 - h, x + 80, 800), radius=28, fill=(64 + i * 20, 200 - i * 12, 170, 255))
    return im.resize((px, px), Image.LANCZOS)
images = []
for pt in (16, 32, 128, 256, 512):
    for sc in (1, 2):
        name = f"icon_{pt}x{pt}@{sc}x.png"; draw(pt * sc).save(icon / name)
        images.append({"idiom": "mac", "scale": f"{sc}x", "size": f"{pt}x{pt}", "filename": name})
(icon / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2))
