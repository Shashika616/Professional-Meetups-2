"""Draws screens.py as an Excalidraw board: one phone frame per screen,
rows by area, every control drawn, every navigation as a bound arrow with
its label (and its gate, where one exists).

    python3 build_excalidraw.py  ->  TieHere-wireframes.excalidraw

Open the file at excalidraw.com (File > Open) or with the VS Code
Excalidraw extension. Everything is editable; arrows stay attached.
"""
import json
import random
import textwrap

from screens import AREAS, BY_ID, SCREENS, NAV, NAV_TARGETS, edges

random.seed(7)

# ------------------------------------------------------------- palette
INK = "#151b21"
MUTED = "#5d6873"
HAIR = "#c9d1d8"
FRAME = "#0f1318"
GREEN = "#34c24c"
GREEN_SOFT = "#e5f7e9"
BLUE = "#2a6b90"
BLUE_SOFT = "#e2eef5"
PAPER = "#ffffff"
NOTE = "#fff7d6"
SHEET = "#f1f4f7"

FONT = 2          # Helvetica
FONT_MONO = 3     # Cascadia

W = 300           # phone frame width
PAD = 14
GAP_X = 110       # horizontal gap between frames (arrow lanes live here)
GAP_Y = 160       # vertical gap between rows
ROW_LABEL_H = 60

elements = []
_ids = 0


def nid():
    global _ids
    _ids += 1
    return f"e{_ids:04d}"


def base(kind, x, y, w, h, **kw):
    el = dict(
        id=nid(), type=kind, x=x, y=y, width=w, height=h, angle=0,
        strokeColor=INK, backgroundColor="transparent", fillStyle="solid",
        strokeWidth=1, strokeStyle="solid", roughness=0, opacity=100,
        groupIds=[], frameId=None, roundness=None, seed=random.randint(1, 2**31),
        version=1, versionNonce=random.randint(1, 2**31), isDeleted=False,
        boundElements=[], updated=1, link=None, locked=False,
    )
    el.update(kw)
    elements.append(el)
    return el


def rect(x, y, w, h, stroke=INK, fill="transparent", radius=8, width=1, dash=False, group=None):
    el = base("rectangle", x, y, w, h, strokeColor=stroke, backgroundColor=fill,
              strokeWidth=width, strokeStyle="dashed" if dash else "solid",
              roundness={"type": 3, "value": radius} if radius else None)
    if group:
        el["groupIds"] = [group]
    return el


def wrap(text, w, size):
    cols = max(8, int((w - 2 * PAD) / (size * 0.52)))
    lines = []
    for para in text.split("\n"):
        lines.extend(textwrap.wrap(para, cols) or [""])
    return lines


def text(x, y, w, s, size=12, color=INK, align="left", bold=False, font=FONT, group=None, container=None):
    lines = wrap(s, w, size) if w else [s]
    lh = 1.25
    h = len(lines) * size * lh
    tw = w if w else max(len(l) for l in lines) * size * 0.52
    el = base("text", x, y, tw, h, strokeColor=color, text="\n".join(lines),
              fontSize=size, fontFamily=font, textAlign=align, verticalAlign="top",
              baseline=size, containerId=container, originalText=s, lineHeight=lh,
              autoResize=False)
    if bold:
        el["fontWeight"] = 700
    if group:
        el["groupIds"] = [group]
    return el, h


# ---------------------------------------------------------- draw a screen
def draw_screen(s, x, y):
    """Returns (frame element, height, {item_index: rect element})."""
    g = f"g_{s['id']}"
    inner_w = W - 2 * PAD
    cy = y + 16
    anchors = {}
    frame = rect(x, y, W, 10, stroke=FRAME, fill=PAPER, radius=26, width=2, group=g)

    # title strip above the frame
    t, th = text(x, y - 34, W, s["title"], size=15, bold=True, group=g)
    text(x, y - 34 + th + 2, W, s["file"], size=9, color=MUTED, font=FONT_MONO, group=g)

    def item(it, idx, ix=x + PAD, iw=inner_w, sheet=False):
        nonlocal cy
        kind = it[0]
        if kind == "bar":
            text(ix, cy, 20, "‹", size=16, group=g)
            text(ix + 22, cy + 1, iw - 22, it[1], size=11, bold=True, color=INK, group=g)
            cy += 26
            base("line", ix, cy - 4, iw, 0, strokeColor=HAIR, points=[[0, 0], [iw, 0]], groupIds=[g])
            cy += 6
        elif kind == "h":
            _, h = text(ix, cy, iw, it[1], size=14, bold=True, group=g)
            cy += h + 8
        elif kind == "p":
            small = it[1].isupper()
            _, h = text(ix, cy, iw, it[1], size=9 if small else 10.5, color=MUTED, bold=small, group=g)
            cy += h + 6
        elif kind in ("btn", "sec"):
            label = it[1]
            lines = wrap(label, iw, 10)
            h = 12 + len(lines) * 13
            r = rect(ix, cy, iw, h, stroke=GREEN if kind == "btn" else BLUE,
                     fill=GREEN_SOFT if kind == "btn" else "transparent", radius=14,
                     width=1.5, group=g)
            text(ix, cy + 6, iw, label, size=10, bold=True, align="center",
                 color=INK if kind == "btn" else BLUE, group=g)
            anchors[idx] = r
            cy += h + 8
        elif kind == "link":
            _, h = text(ix, cy, iw, it[1], size=10, color=BLUE, align="center", bold=True, group=g)
            r = rect(ix, cy - 3, iw, h + 6, stroke="transparent", radius=4, group=g)
            anchors[idx] = r
            cy += h + 8
        elif kind == "input":
            r = rect(ix, cy, iw, 28, stroke=HAIR, radius=8, group=g)
            text(ix + 10, cy + 8, iw - 20, it[1], size=10, color=MUTED, group=g)
            cy += 36
        elif kind == "otp":
            bw = (iw - 5 * 6) / 6
            for i in range(6):
                rect(ix + i * (bw + 6), cy, bw, 34, stroke=HAIR, radius=6, group=g)
            cy += 42
        elif kind == "check":
            rect(ix, cy + 1, 14, 14, stroke=INK, radius=3, group=g)
            _, h = text(ix + 22, cy, iw - 22, it[1], size=10, group=g)
            cy += max(h, 14) + 6
        elif kind == "tabs":
            labels, sel = it[1], it[2]
            tx = ix
            row_y = cy
            for i, lab in enumerate(labels):
                tw = len(lab) * 5.6 + 8
                if tx + tw > ix + iw:
                    tx = ix
                    row_y += 20
                text(tx, row_y, tw, lab, size=9, bold=True,
                     color=GREEN if i == sel else MUTED, group=g)
                if i == sel:
                    base("line", tx, row_y + 14, tw - 8, 0, strokeColor=GREEN, strokeWidth=2,
                         points=[[0, 0], [tw - 8, 0]], groupIds=[g])
                tx += tw + 10
            cy = row_y + 24
        elif kind == "chips":
            tx = ix
            row_y = cy
            for lab in it[1]:
                tw = len(lab) * 5.4 + 16
                if tx + tw > ix + iw:
                    tx = ix
                    row_y += 26
                rect(tx, row_y, tw, 20, stroke=HAIR, radius=10, group=g)
                text(tx, row_y + 5, tw, lab, size=8.5, align="center", color=INK, group=g)
                tx += tw + 6
            cy = row_y + 28
        elif kind == "card":
            lines = it[1]
            h = 10
            for l in lines:
                h += len(wrap(l, iw - 16, 9.5)) * 12 + 3
            r = rect(ix, cy, iw, h, stroke=HAIR, fill="#f8fafb", radius=10, group=g)
            base("line", ix, cy, 0, h, strokeColor=GREEN, strokeWidth=3, points=[[0, 0], [0, h]], groupIds=[g])
            ly = cy + 6
            for i, l in enumerate(lines):
                _, lh_ = text(ix + 10, ly, iw - 16, l, size=9.5, bold=(i == 0), color=INK if i == 0 else MUTED, group=g)
                ly += lh_ + 3
            anchors[idx] = r
            cy += h + 8
        elif kind == "row":
            label, detail, target = it[1], it[2], it[3]
            h = 14 + (12 if detail else 0) + 10
            r = rect(ix, cy, iw, h, stroke=HAIR, radius=8, group=g)
            text(ix + 10, cy + 6, iw - 34, label, size=10, bold=True, group=g)
            if detail:
                text(ix + 10, cy + 20, iw - 34, detail, size=8.5, color=MUTED, group=g)
            text(ix + iw - 18, cy + h / 2 - 8, 12, "›", size=14, color=MUTED, group=g)
            anchors[idx] = r
            cy += h + 6
        elif kind == "state":
            lines = wrap(it[1], iw - 10, 8.5)
            h = len(lines) * 10.6 + 10
            rect(ix, cy, iw, h, stroke="#e6d9a0", fill=NOTE, radius=6, group=g)
            text(ix + 6, cy + 5, iw - 12, it[1], size=8.5, color="#5a4d10", group=g)
            cy += h + 8
        elif kind == "sheet":
            title, sub = it[1], it[2]
            top = cy
            # placeholder height; children draw, then the box is sized
            box = rect(ix - 6, top, iw + 12, 10, stroke=HAIR, fill=SHEET, radius=16, group=g)
            base("line", ix + iw / 2 - 16, top + 6, 32, 0, strokeColor=HAIR, strokeWidth=3,
                 points=[[0, 0], [32, 0]], groupIds=[g])
            cy = top + 14
            text(ix, cy, iw, title, size=9, bold=True, color=MUTED, group=g)
            cy += 18
            for j, sub_it in enumerate(sub):
                item(sub_it, (idx, j), ix, iw, sheet=True)
            box["height"] = cy - top + 4
            cy += 12
        elif kind == "nav":
            active = it[1]
            cy += 4
            base("line", x, cy, W, 0, strokeColor=HAIR, points=[[0, 0], [W, 0]], groupIds=[g])
            cw = W / 4
            for i, lab in enumerate(NAV):
                r = rect(x + i * cw + 4, cy + 4, cw - 8, 30, stroke="transparent", radius=4, group=g)
                text(x + i * cw, cy + 12, cw, lab, size=8.5, bold=True, align="center",
                     color=BLUE if i == active else MUTED, group=g)
                anchors[("nav", i)] = r
            cy += 40

    for idx, it in enumerate(s["items"]):
        item(it, idx)

    h = cy - y + 10
    frame["height"] = h
    # frame must sit behind everything drawn after it: move it to the front
    # of the list (Excalidraw paints in array order)
    elements.remove(frame)
    elements.insert(0, frame)
    return frame, h, anchors


# ---------------------------------------------------------------- layout
positions = {}   # id -> (x, y, frame, anchors)
y = 80
for area_id, area_title in AREAS:
    row = [s for s in SCREENS if s["area"] == area_id]
    text(40, y, 800, area_title.upper(), size=22, bold=True, color=INK)
    text(40, y + 30, 900, "  ·  ".join(s["title"] for s in row), size=10, color=MUTED)
    fy = y + ROW_LABEL_H + 40
    x = 40
    tallest = 0
    for s in row:
        frame, h, anchors = draw_screen(s, x, fy)
        positions[s["id"]] = (x, fy, frame, anchors)
        tallest = max(tallest, h)
        x += W + GAP_X
    y = fy + tallest + GAP_Y

# --------------------------------------------------------------- arrows
def bind(arrow, el):
    el["boundElements"].append({"id": arrow["id"], "type": "arrow"})


def draw_arrow(src_rect, dst_frame, label, lane):
    sx0, sy = src_rect["x"], src_rect["y"] + src_rect["height"] / 2
    sw = src_rect["width"]
    dx0, dy0 = dst_frame["x"], dst_frame["y"]
    dw, dh = dst_frame["width"], dst_frame["height"]
    to_right = dx0 > sx0 + sw
    to_left = dx0 + dw < sx0
    if to_right:
        start = (sx0 + sw, sy)
        end = (dx0, dy0 + 40 + lane * 18)
        mid_x = sx0 + sw + 20 + lane * 10
        pts = [(0, 0), (mid_x - start[0], 0), (mid_x - start[0], end[1] - start[1]), (end[0] - start[0], end[1] - start[1])]
    elif to_left:
        start = (sx0, sy)
        end = (dx0 + dw, dy0 + 40 + lane * 18)
        mid_x = sx0 - 20 - lane * 10
        pts = [(0, 0), (mid_x - start[0], 0), (mid_x - start[0], end[1] - start[1]), (end[0] - start[0], end[1] - start[1])]
    else:
        # same column: leave from the right, run down/up the lane, enter the top or bottom
        start = (sx0 + sw, sy)
        going_down = dy0 > sy
        end = (dx0 + dw / 2 + lane * 14, dy0 if going_down else dy0 + dh)
        mid_x = sx0 + sw + 24 + lane * 10
        mid_y = end[1] - 24 if going_down else end[1] + 24
        pts = [(0, 0), (mid_x - start[0], 0), (mid_x - start[0], mid_y - start[1]),
               (end[0] - start[0], mid_y - start[1]), (end[0] - start[0], end[1] - start[1])]
    arrow = base("arrow", start[0], start[1], abs(pts[-1][0]), abs(pts[-1][1]),
                 strokeColor=BLUE, strokeWidth=1.2, points=[list(p) for p in pts],
                 startArrowhead=None, endArrowhead="arrow", lastCommittedPoint=None,
                 startBinding={"elementId": src_rect["id"], "focus": 0, "gap": 2},
                 endBinding={"elementId": dst_frame["id"], "focus": 0, "gap": 2},
                 roundness={"type": 2})
    bind(arrow, src_rect)
    bind(arrow, dst_frame)
    # label, bound to the arrow so Excalidraw keeps it on the line
    lx = start[0] + pts[1][0] + 6
    ly = start[1] + (pts[2][1] / 2) - 8
    lab, lh_ = text(lx, ly, 0, label, size=9, color=BLUE, font=FONT_MONO)
    lab["containerId"] = arrow["id"]
    lab["backgroundColor"] = PAPER
    arrow["boundElements"].append({"id": lab["id"], "type": "text"})


lanes = {}
for s in SCREENS:
    x, fy, frame, anchors = positions[s["id"]]

    def walk(items, prefix=None):
        for i, it in enumerate(items):
            idx = i if prefix is None else (prefix, i)
            kind = it[0]
            targets = []
            if kind in ("btn", "sec", "link"):
                t = it[2]
                if isinstance(t, list):
                    targets = [(tid, f"{cond}") for cond, tid in t]
                elif t:
                    targets = [(t, "")]
            elif kind == "card" and it[2]:
                targets = [(it[2], "")]
            elif kind == "row" and it[3]:
                targets = [(it[3], "")]
            elif kind == "sheet":
                walk(it[2], i)
                continue
            src = anchors.get(idx)
            if not src:
                continue
            for tid, cond in targets:
                key = (s["id"], tid)
                lane = lanes.get(tid, 0)
                lanes[tid] = lane + 1
                label = cond if cond else (it[1] if kind != "card" else "tap")
                draw_arrow(src, positions[tid][2], label, lane % 6)

    walk(s["items"])

# The tab bar: one dashed note instead of 16 arrows.
text(40, y, 1200, "Bottom bar on Home, Events, Safety and Profile: HOME / EVENTS / SAFETY / PROFILE switch between those four screens in place (no push).",
     size=11, color=MUTED)

doc = {
    "type": "excalidraw",
    "version": 2,
    "source": "TieHere docs/design/wireframes/build_excalidraw.py",
    "elements": elements,
    "appState": {"viewBackgroundColor": "#f6f7f5", "gridSize": None},
    "files": {},
}
with open("TieHere-wireframes.excalidraw", "w") as f:
    json.dump(doc, f, indent=1)
print(f"{len(SCREENS)} screens, {len(edges())} edges, {len(elements)} elements")
