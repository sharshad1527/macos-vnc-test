#!/usr/bin/env python3
"""Score a captured frame. Prints one line: SCORE <nonblack%> <VERDICT>"""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/f.png"
try:
    im = Image.open(path).convert("RGB")
except Exception as e:
    print(f"SCORE 0.00 NO-FRAME ({type(e).__name__})")
    sys.exit(0)

px = list(im.getdata())
# A lone mouse cursor can be ~0.02% - not a desktop.
nonblack = 100.0 * sum(1 for p in px if max(p) > 12) / len(px)
verdict = "REAL-DESKTOP" if nonblack > 1.0 else "BLACK"
print(f"SCORE {nonblack:.2f} {verdict} {im.size[0]}x{im.size[1]}")
