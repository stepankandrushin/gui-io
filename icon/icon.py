#!/usr/bin/env python3
"""Draws GuiIO's app icon and writes AppIcon.iconset next to this file (build.sh makes the .icns).

A display whose corner is folded like a page (the screen is a file), a shell prompt on it and the
pointer over it: a terminal sees the screen and drives it. The body follows macOS's app icon grid,
an 824 px continuous-corner square on a 1024 px canvas with room for its shadow, so macOS 26 and
later show it as it is instead of shrinking it onto a gray tile.

    python3 icon/icon.py        # needs pycairo and Pillow (Debian: python3-cairo python3-pil)
"""
import math, os
import cairo
from PIL import Image, ImageFilter

S = 1024
# continuous ("squircle") corner, iOS 7 coefficients: (along incoming edge, along outgoing edge) * r
CORNER = [
    ('l', (1.52866471, 0)),
    ('c', (1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600)),
    ('l', (0.63149399, 0.07491100)),
    ('c', (0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491176, 0.63149399)),
    ('l', (0.06549569, 0.66993493)),
    ('c', (0, 0.86840701), (0, 1.08849299), (0, 1.52866483)),
]


def squircle(ctx, x, y, w, h, r):
    r = min(r, min(w, h) / 2 / 1.52866483)
    corners = [((x + w, y), (1, 0), (0, 1)), ((x + w, y + h), (0, 1), (-1, 0)),
               ((x, y + h), (-1, 0), (0, -1)), ((x, y), (0, -1), (1, 0))]
    ctx.new_path()
    first = True
    for (cx, cy), din, dout in corners:
        def p(XY):
            X, Y = XY
            return (cx - X * r * din[0] + Y * r * dout[0], cy - X * r * din[1] + Y * r * dout[1])
        for seg in CORNER:
            if seg[0] == 'l':
                pt = p(seg[1])
                if first:
                    ctx.move_to(*pt); first = False
                else:
                    ctx.line_to(*pt)
            else:
                a, b, c = p(seg[1]), p(seg[2]), p(seg[3])
                ctx.curve_to(*a, *b, *c)
    ctx.close_path()


def rgb(h, a=1.0):
    h = h.lstrip('#')
    return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, a)


def vgrad(y0, y1, c0, c1):
    g = cairo.LinearGradient(0, y0, 0, y1)
    g.add_color_stop_rgba(0, *rgb(c0) if isinstance(c0, str) else c0)
    g.add_color_stop_rgba(1, *rgb(c1) if isinstance(c1, str) else c1)
    return g


def layer():
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, S, S)
    ctx = cairo.Context(surf)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    return surf, ctx


def to_pil(surf):
    surf.flush()
    return Image.frombuffer('RGBA', (S, S), bytes(surf.get_data()), 'raw', 'BGRa', surf.get_stride(), 1).copy()


def shadow_of(img, blur, dy, alpha, dx=0):
    a = img.getchannel('A').point(lambda v: int(v * alpha))
    sh = Image.new('RGBA', img.size, (0, 0, 0, 0))
    black = Image.new('RGBA', img.size, (0, 0, 0, 255))
    sh.paste(black, (0, 0), a)
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    out.paste(sh, (dx, dy))
    return out


def compose(layers):
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    for item in layers:
        img, shadow = item if isinstance(item, tuple) else (item, None)
        if shadow:
            out = Image.alpha_composite(out, shadow_of(img, *shadow))
        out = Image.alpha_composite(out, img)
    return out


# ---------- pieces ----------

def background(c0, c1):
    surf, ctx = layer()
    squircle(ctx, 100, 100, 824, 824, 185.4)
    ctx.set_source(vgrad(100, 924, c0, c1))
    ctx.fill_preserve()
    # soft light from the top
    g = cairo.RadialGradient(512, 40, 0, 512, 40, 700)
    g.add_color_stop_rgba(0, 1, 1, 1, 0.22)
    g.add_color_stop_rgba(1, 1, 1, 1, 0)
    ctx.set_source(g)
    ctx.fill()
    return to_pil(surf)


def pointer_path(ctx, tx, ty, h):
    pts = [(0, 0), (0, 0.79), (0.175, 0.63), (0.305, 0.94), (0.44, 0.882), (0.315, 0.592), (0.535, 0.592)]
    ctx.new_path()
    for i, (px, py) in enumerate(pts):
        (ctx.move_to if i == 0 else ctx.line_to)(tx + px * h, ty + py * h)
    ctx.close_path()


def pointer(tx, ty, h, fill='#FFFFFF', edge='#0B0F19', ew=None):
    surf, ctx = layer()
    ew = ew or h * 0.075
    pointer_path(ctx, tx, ty, h)
    ctx.set_line_width(ew)
    ctx.set_source_rgba(*rgb(edge))
    ctx.stroke_preserve()
    ctx.set_source_rgba(*rgb(fill))
    ctx.fill()
    return to_pil(surf)


def prompt(x, y, size, color='#5BF08F', width=None):
    surf, ctx = layer()
    w = width or size * 0.30
    ctx.set_line_width(w)
    ctx.set_source_rgba(*rgb(color))
    ctx.move_to(x, y); ctx.line_to(x + size * 0.55, y + size * 0.5); ctx.line_to(x, y + size)
    ctx.stroke()
    ctx.move_to(x + size * 0.85, y + size); ctx.line_to(x + size * 1.55, y + size)
    ctx.stroke()
    return to_pil(surf)


def dark_screen(sy, sh):
    return vgrad(sy, sy + sh, '#18233A', '#0B1120')


def file_monitor(x, y, w, h, fold, screen_fill, bezel=26):
    surf, ctx = layer()
    cx = x + w / 2
    ctx.new_path()
    nt, nb = 64, 82
    ctx.move_to(cx - nt, y + h - 10); ctx.line_to(cx + nt, y + h - 10)
    ctx.line_to(cx + nb, y + h + 70); ctx.line_to(cx - nb, y + h + 70); ctx.close_path()
    ctx.set_source(vgrad(y + h, y + h + 70, '#C9D2E3', '#E6EBF3'))
    ctx.fill()
    squircle(ctx, cx - 150, y + h + 62, 300, 30, 14)
    ctx.set_source(vgrad(y + h + 62, y + h + 92, '#F3F6FB', '#D5DCE8'))
    ctx.fill()
    def body(ctx, x, y, w, h, r, f):
        ctx.new_path()
        ctx.move_to(x + r, y)
        ctx.line_to(x + w - f, y)
        ctx.line_to(x + w, y + f)
        ctx.line_to(x + w, y + h - r)
        ctx.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        ctx.line_to(x + r, y + h)
        ctx.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        ctx.line_to(x, y + r)
        ctx.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
        ctx.close_path()
    body(ctx, x, y, w, h, 40, fold)
    ctx.set_source(vgrad(y, y + h, '#FFFFFF', '#E4E9F2'))
    ctx.fill()
    sx, sy, sw, sh = x + bezel, y + bezel, w - 2 * bezel, h - 2 * bezel
    body(ctx, sx, sy, sw, sh, 20, fold - bezel * 0.6)
    ctx.set_source(screen_fill(sy, sh))
    ctx.fill()
    img = to_pil(surf)
    surf, ctx = layer()
    ctx.new_path()
    ctx.move_to(x + w - fold, y); ctx.line_to(x + w - fold, y + fold - 18)
    ctx.arc_negative(x + w - fold + 18, y + fold - 18, 18, math.pi, math.pi / 2)
    ctx.line_to(x + w, y + fold); ctx.close_path()
    g = cairo.LinearGradient(x + w - fold, y + fold, x + w - fold / 2, y + fold / 2)
    g.add_color_stop_rgba(0, *rgb('#FFFFFF')); g.add_color_stop_rgba(1, *rgb('#C3CDDD'))
    ctx.set_source(g)
    ctx.fill()
    flap = to_pil(surf)
    return compose([img, (flap, (9, 7, 0.45, -6))]), (sx, sy, sw, sh)


def icon():
    bg = background('#5E8DFF', '#2B3BD1')
    mon, (sx, sy, sw, sh) = file_monitor(192, 226, 640, 440, 136, dark_screen)
    pr = prompt(sx + 46, sy + 50, 104, width=30)
    pt = pointer(sx + 300, sy + 128, 330)
    return compose([(bg, (12, 10, 0.35)), (mon, (18, 12, 0.35)), pr, (pt, (10, 10, 0.45))])


if __name__ == '__main__':
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'AppIcon.iconset')
    os.makedirs(out, exist_ok=True)
    big = icon()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            img = big if px == S else big.resize((px, px), Image.LANCZOS)
            name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            img.save(os.path.join(out, name), optimize=True)
    print(out)
