#!/usr/bin/env python3
"""Draw PowerFlow's app icon: the diagram the app is built around, reduced to
a silhouette that still reads at 32px."""
import os, subprocess, sys
from PIL import Image, ImageDraw

S = 1024
BG_TOP, BG_BOT = (46, 47, 57), (26, 27, 33)
SURFACE = (150, 150, 158)
IVORY = (242, 229, 185)
BLUE = (22, 112, 212)


def bez(p0, p1, p2, p3, n=60):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        x = u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0]
        y = u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1]
        out.append((x, y))
    return out


def ribbon(d, x0, x1, sy0, sy1, ey0, ey1, fill):
    mid = (x0 + x1) / 2
    pts = bez((x0, sy0), (mid, sy0), (mid, ey0), (x1, ey0))
    pts += [(x1, ey1)]
    pts += bez((x1, ey1), (mid, ey1), (mid, sy1), (x0, sy1))
    d.polygon(pts, fill=fill)


def draw(size):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # vertical gradient inside a squircle-ish rounded rect
    grad = Image.new("RGB", (1, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / S
        gd.point((0, y), fill=tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3)))
    grad = grad.resize((S, S))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=228, fill=255)
    img.paste(grad, (0, 0), mask)

    # charge capsule
    d.rounded_rectangle([150, 168, 874, 288], radius=60, fill=(64, 64, 70))
    d.rounded_rectangle([150, 168, 722, 288], radius=60, fill=BLUE)

    # sankey: plug + battery on the left, machine on the right
    d.rounded_rectangle([150, 396, 268, 726], radius=59, fill=SURFACE)
    d.rounded_rectangle([150, 786, 268, 872], radius=43, fill=SURFACE)
    d.rounded_rectangle([756, 432, 874, 836], radius=59, fill=SURFACE)
    ribbon(d, 300, 724, 396, 726, 432, 700, SURFACE)
    ribbon(d, 300, 724, 786, 872, 706, 836, SURFACE)
    # the ivory plug mark, the one warm accent
    d.rounded_rectangle([192, 520, 226, 602], radius=17, fill=IVORY)
    return img.resize((size, size), Image.LANCZOS)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns"
    iconset = out.replace(".icns", ".iconset")
    os.makedirs(iconset, exist_ok=True)
    for px, names in [(16, ["16x16"]), (32, ["16x16@2x", "32x32"]), (64, ["32x32@2x"]),
                      (128, ["128x128"]), (256, ["128x128@2x", "256x256"]),
                      (512, ["256x256@2x", "512x512"]), (1024, ["512x512@2x"])]:
        im = draw(px)
        for n in names:
            im.save(os.path.join(iconset, f"icon_{n}.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    subprocess.run(["rm", "-rf", iconset], check=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
