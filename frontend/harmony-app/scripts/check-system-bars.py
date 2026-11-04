#!/usr/bin/env python3
"""Check real device screenshots for the system-bar background regression.

Requires Pillow in the local development Python environment. This only reads images.
"""
import argparse
from collections import Counter
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('screenshot')
parser.add_argument('--background', default='#212731')
args = parser.parse_args()
expected = tuple(int(args.background.lstrip('#')[i:i + 2], 16) for i in (0, 2, 4))
image = Image.open(args.screenshot).convert('RGB')
width, height = image.size
failed = False
# Majority sampling ignores the time, signal icons, camera cutout and gesture handle.
for label, fraction in [('status', 0.025), ('navigation', 0.985)]:
    y = int(height * fraction)
    color, count = Counter(image.getpixel((x, y)) for x in range(width // 8, 7 * width // 8)).most_common(1)[0]
    matches = all(abs(a - b) <= 2 for a, b in zip(color, expected))
    failed |= not matches
    print(f'{label}: {color}, expected {expected}: {"PASS" if matches else "FAIL"}')
raise SystemExit(1 if failed else 0)
