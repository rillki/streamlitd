#!/usr/bin/env python3
"""Build assets/favicon.ico from the PNGs rendered by tools/gen_favicon.js (needs Pillow)."""
import os
from PIL import Image
a = os.path.join(os.path.dirname(__file__), "..", "assets")
imgs = [Image.open(os.path.join(a, f"favicon-{s}.png")).convert("RGBA") for s in (16, 32, 48)]
imgs[2].save(os.path.join(a, "favicon.ico"), sizes=[(16, 16), (32, 32), (48, 48)], append_images=imgs[:2])
for s in (16, 48):  # only needed to build the .ico
    os.remove(os.path.join(a, f"favicon-{s}.png"))
print("favicon.ico")
