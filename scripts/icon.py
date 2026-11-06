#!/usr/bin/env python3
"""Generate the plugin icons (an original cloud + equaliser mark).

  <name>.svg      24x24 monochrome glyph, all #000: Material Skin swaps it in
                  for <name>_svg.png and recolours it per theme
  <name>_svg.png  512x512 full-bleed colour tile for other skins/apps

The tile is full-bleed (no transparent rounded corners): clients round or
crop it themselves, and transparent corners rendered on white showed up as
white slivers on dark themes. PNG rendering uses macOS QuickLook.

LMS and browsers cache resized icons by path, so bump NAME when the art
changes (and update install.xml).

Menu icons: MTL_icon_<name>.png for each Material Design icon in MENU_ICONS.
Material Skin sees "MTL_icon_<name>" in the path and draws its own icon of
that name (themed); other skins show the PNG: the same glyph, white on the
logo's gradient tile. Glyphs are Google's Material Icons (Apache-2.0),
fetched from the npm CDN when this script runs.
"""

import math
import os
import re
import shutil
import subprocess
import tempfile
import urllib.request

NAME = "mixcloud-direct-2"
OUT = os.path.join(os.path.dirname(__file__), "..", "src", "MixcloudDirect",
                   "HTML", "EN", "plugins", "MixcloudDirect", "html", "images")

# cloud = three circles on a flat base, in a 512 box
LEFT = (160, 308, 78)
MID = (258, 240, 112)
RIGHT = (352, 302, 84)
BASE_Y = 386
# equaliser bars cut out of the cloud: (centre x, height)
BARS = [(184, 52), (221, 104), (258, 150), (295, 92), (332, 58)]
BAR_W, BAR_CY = 24, 290


def intersect(a, b, upper=True):
    (x0, y0, r0), (x1, y1, r1) = a, b
    d = math.hypot(x1 - x0, y1 - y0)
    l = (r0 * r0 - r1 * r1 + d * d) / (2 * d)
    h = math.sqrt(r0 * r0 - l * l)
    mx, my = x0 + l * (x1 - x0) / d, y0 + l * (y1 - y0) / d
    p = (mx + h * (y1 - y0) / d, my - h * (x1 - x0) / d)
    q = (mx - h * (y1 - y0) / d, my + h * (x1 - x0) / d)
    return min(p, q, key=lambda t: t[1]) if upper else max(p, q, key=lambda t: t[1])


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def cloud_path():
    lx, ly, lr = LEFT
    rx, ry, rr = RIGHT
    a = intersect(LEFT, MID)
    b = intersect(MID, RIGHT)
    # where the side circles meet the flat base
    lb = (lx - math.sqrt(lr * lr - (BASE_Y - ly) ** 2), BASE_Y) if BASE_Y - ly < lr else (lx, ly + lr)
    rb = (rx + math.sqrt(rr * rr - (BASE_Y - ry) ** 2), BASE_Y) if BASE_Y - ry < rr else (rx, ry + rr)
    return (
        f"M{f(lb[0])} {f(lb[1])}"
        f"A{lr} {lr} 0 0 1 {f(a[0])} {f(a[1])}"
        f"A{MID[2]} {MID[2]} 0 0 1 {f(b[0])} {f(b[1])}"
        f"A{rr} {rr} 0 0 1 {f(rb[0])} {f(rb[1])}Z"
    )


def bar_paths():
    r = BAR_W / 2
    out = []
    for cx, h in BARS:
        x0, x1 = cx - r, cx + r
        top, bot = BAR_CY - h / 2 + r, BAR_CY + h / 2 - r
        # counter-clockwise pill, so it's a hole under either fill rule
        out.append(f"M{f(x1)} {f(top)}A{f(r)} {f(r)} 0 0 0 {f(x0)} {f(top)}V{f(bot)}"
                   f"A{f(r)} {f(r)} 0 0 0 {f(x1)} {f(bot)}Z")
    return "".join(out)


MARK = cloud_path() + bar_paths()

TILE = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
<stop offset="0" stop-color="#7b5cff"/><stop offset="1" stop-color="#2a1a8f"/></linearGradient></defs>
<rect width="512" height="512" fill="url(#g)"/>
<path fill="#ffffff" fill-rule="evenodd" d="{MARK}"/>
</svg>
"""

# 24x24 with the mark scaled into a 20x20 area (2 px margin)
scale = 20 / (RIGHT[0] + RIGHT[2] - (LEFT[0] - LEFT[2]))
GLYPH = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
<path fill="#000" fill-rule="evenodd" transform="translate(2 {f(12 - (MID[1] - MID[2] + BASE_Y) / 2 * scale)}) scale({scale:.5f}) translate({-(LEFT[0] - LEFT[2])} 0)" d="{MARK}"/>
</svg>
"""


MENU_ICONS = ["account_circle", "search", "library_music", "mic", "link",
              "queue_music", "favorite", "history", "playlist_play", "people",
              "trending_up", "new_releases", "more_horiz"]
GLYPH_URL = "https://cdn.jsdelivr.net/npm/@material-design-icons/svg@0.14.13/filled/{}.svg"


def menu_tile(name):
    with urllib.request.urlopen(GLYPH_URL.format(name), timeout=30) as r:
        svg = r.read().decode()
    paths = "".join(re.findall(r"<path[^>]*/>", svg))
    # the logo's background, with the 24-unit glyph scaled to 264 px, centred
    background = TILE.split("<path")[0].split(">", 1)[1]
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">'
            f'{background}<g fill="#ffffff" transform="translate(124 124) scale(11)">{paths}</g></svg>')


def render(svgs):
    """{filename.png: svg text} -> PNGs in OUT, via QuickLook"""
    tmp = tempfile.mkdtemp()
    sources = []
    for png, svg in svgs.items():
        src = os.path.join(tmp, png[:-4] + ".svg")
        with open(src, "w") as fh:
            fh.write(svg)
        sources.append(src)
    subprocess.run(["qlmanage", "-t", "-s", "512", "-o", tmp] + sources,
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for png in svgs:
        shutil.copy(os.path.join(tmp, png[:-4] + ".svg.png"), os.path.join(OUT, png))


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, NAME + ".svg"), "w") as fh:
        fh.write(GLYPH)

    svgs = {NAME + "_svg.png": TILE}
    svgs.update({f"MTL_icon_{n}.png": menu_tile(n) for n in MENU_ICONS})
    render(svgs)
    print("wrote", NAME + ".svg", ", ".join(svgs))


if __name__ == "__main__":
    main()
