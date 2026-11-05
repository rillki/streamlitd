#!/usr/bin/env python3
"""Shrink docs/images/*.png and build the theme contact sheets (needs Pillow)."""
import glob, os
from PIL import Image

root = os.path.join(os.path.dirname(__file__), "..", "docs", "images")
presets = ["streamlit", "minimal", "ocean", "forest", "sunset", "finance", "solarized", "paper"]

# contact sheets: 4 columns x 2 rows of presets, light and dark
for mode in ("light", "dark"):
    files = [os.path.join(root, f"theme-{p}-{mode}.png") for p in presets]
    if all(os.path.exists(f) for f in files):
        w, h = 480, 300
        sheet = Image.new("RGB", (w * 4, h * 2), "white")
        for i, f in enumerate(files):
            sheet.paste(Image.open(f).convert("RGB").resize((w, h), Image.LANCZOS), ((i % 4) * w, (i // 4) * h))
        sheet.save(os.path.join(root, f"themes-{mode}.png"))

before = after = 0
for f in sorted(glob.glob(os.path.join(root, "*.png"))):
    before += os.path.getsize(f)
    im = Image.open(f).convert("RGB")
    im.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(f, optimize=True)
    after += os.path.getsize(f)
print(f"{len(glob.glob(os.path.join(root, '*.png')))} images, {before // 1024} KB -> {after // 1024} KB")
