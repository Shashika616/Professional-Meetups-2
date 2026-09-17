"""The real screens on an Excalidraw board: every capture as an image
element (embedded), rows by area, and a bound arrow for every hotspot,
labelled with the control and its gate.

    python3 build_excalidraw.py  ->  TieHere-UI-flow.excalidraw
"""
import base64
import json
import os
import random

from flow import AREAS, BY_ID, SCREENS, hotspots, HERE, W, H

random.seed(11)
IMG_W, IMG_H = 300, int(300 * H / W)     # 300 x 667 on the board
GAP_X, GAP_Y = 120, 140
INK, MUTED, BLUE, PAPER = "#151b21", "#5d6873", "#2a6b90", "#ffffff"

elements, files = [], {}
_n = 0


def nid():
    global _n
    _n += 1
    return f"e{_n:04d}"


def base(kind, x, y, w, h, **kw):
    el = dict(id=nid(), type=kind, x=x, y=y, width=w, height=h, angle=0, strokeColor=INK,
              backgroundColor="transparent", fillStyle="solid", strokeWidth=1, strokeStyle="solid",
              roughness=0, opacity=100, groupIds=[], frameId=None, roundness=None,
              seed=random.randint(1, 2**31), version=1, versionNonce=random.randint(1, 2**31),
              isDeleted=False, boundElements=[], updated=1, link=None, locked=False)
    el.update(kw)
    elements.append(el)
    return el


def text(x, y, s, size=12, color=INK, w=None, font=2):
    lines = s.split("\n")
    tw = w or max(len(l) for l in lines) * size * 0.55
    return base("text", x, y, tw, len(lines) * size * 1.25, strokeColor=color, text=s, fontSize=size,
                fontFamily=font, textAlign="left", verticalAlign="top", baseline=size, containerId=None,
                originalText=s, lineHeight=1.25, autoResize=True)


def image(sid, x, y):
    path = os.path.join(HERE, "img", sid + ".jpg")
    data = base64.b64encode(open(path, "rb").read()).decode()
    fid = "f_" + sid.replace("-", "_")
    files[fid] = dict(mimeType="image/jpeg", id=fid, dataURL="data:image/jpeg;base64," + data, created=1)
    return base("image", x, y, IMG_W, IMG_H, fileId=fid, status="saved", scale=[1, 1],
                roundness={"type": 3, "value": 18})


# layout: one row per area
pos = {}
y = 80
for aid, atitle in AREAS:
    row = [s for s in SCREENS if s["area"] == aid]
    text(40, y, atitle.upper(), size=24)
    x = 40
    fy = y + 60
    for s in row:
        el = image(s["id"], x, fy)
        text(x, fy - 26, s["title"], size=13)
        if s["note"]:
            text(x, fy + IMG_H + 6, s["note"], size=9, color=MUTED, w=IMG_W)
        pos[s["id"]] = el
        x += IMG_W + GAP_X
    y = fy + IMG_H + GAP_Y


def sx(v):
    return v * IMG_W / W


def sy(v):
    return v * IMG_H / H


lanes = {}
for s in SCREENS:
    src_img = pos[s["id"]]
    for hs in hotspots(s):
        if hs["label"].endswith(" tab"):
            continue                       # the tab bar: one note instead of 400 arrows
        r = hs["rect"]
        if not r:
            continue
        tgt = pos[hs["target"]]
        if tgt is src_img:
            continue
        # a small rectangle on the image marking the control, so the arrow
        # visibly leaves the real button
        rx, ry = src_img["x"] + sx(r[0]), src_img["y"] + sy(r[1])
        rw, rh = sx(r[2] - r[0]), sy(r[3] - r[1])
        mark = base("rectangle", rx, ry, rw, rh, strokeColor=BLUE, strokeWidth=1.5,
                    backgroundColor="#2a6b9020", roundness={"type": 3, "value": 4})
        lane = lanes.get(hs["target"], 0)
        lanes[hs["target"]] = lane + 1
        to_right = tgt["x"] > src_img["x"] + IMG_W
        to_left = tgt["x"] + IMG_W < src_img["x"]
        if to_right:
            start = (rx + rw, ry + rh / 2)
            end = (tgt["x"], tgt["y"] + 20 + (lane % 8) * 14)
            mid = start[0] + 18 + (lane % 6) * 8
            pts = [(0, 0), (mid - start[0], 0), (mid - start[0], end[1] - start[1]), (end[0] - start[0], end[1] - start[1])]
        elif to_left:
            start = (rx, ry + rh / 2)
            end = (tgt["x"] + IMG_W, tgt["y"] + 20 + (lane % 8) * 14)
            mid = start[0] - 18 - (lane % 6) * 8
            pts = [(0, 0), (mid - start[0], 0), (mid - start[0], end[1] - start[1]), (end[0] - start[0], end[1] - start[1])]
        else:
            start = (rx + rw, ry + rh / 2)
            down = tgt["y"] > start[1]
            end = (tgt["x"] + IMG_W / 2 + (lane % 6) * 12, tgt["y"] if down else tgt["y"] + IMG_H)
            mid = start[0] + 22 + (lane % 6) * 8
            midy = end[1] - 26 if down else end[1] + 26
            pts = [(0, 0), (mid - start[0], 0), (mid - start[0], midy - start[1]), (end[0] - start[0], midy - start[1]), (end[0] - start[0], end[1] - start[1])]
        arrow = base("arrow", start[0], start[1], abs(pts[-1][0]), abs(pts[-1][1]), strokeColor=BLUE,
                     strokeWidth=1.2, points=[list(p) for p in pts], startArrowhead=None, endArrowhead="arrow",
                     lastCommittedPoint=None, roundness={"type": 2},
                     startBinding={"elementId": mark["id"], "focus": 0, "gap": 1},
                     endBinding={"elementId": tgt["id"], "focus": 0, "gap": 2})
        mark["boundElements"].append({"id": arrow["id"], "type": "arrow"})
        tgt["boundElements"].append({"id": arrow["id"], "type": "arrow"})
        label = hs["label"] + ("   [" + hs["gate"] + "]" if hs["gate"] else "")
        lab = text(start[0] + pts[1][0] + 4, start[1] + pts[2][1] / 2 - 7, label, size=8, color=BLUE, font=3)
        lab["containerId"] = arrow["id"]
        lab["backgroundColor"] = PAPER
        arrow["boundElements"].append({"id": lab["id"], "type": "text"})

text(40, y, "Bottom bar (HOME / EVENTS / SAFETY / PROFILE) on every tab screen switches between Home, Events, Safety Center and Profile in place. "
     "Dumps and full-size PNGs: docs/design/ui-flow/.", size=11, color=MUTED)

doc = {"type": "excalidraw", "version": 2, "source": "TieHere docs/design/ui-flow/build_excalidraw.py",
       "elements": elements, "appState": {"viewBackgroundColor": "#f6f7f5", "gridSize": None}, "files": files}
out = os.path.join(HERE, "TieHere-UI-flow.excalidraw")
with open(out, "w") as f:
    json.dump(doc, f)
print(len(SCREENS), "screens,", sum(1 for e in elements if e["type"] == "arrow"), "arrows,",
      round(os.path.getsize(out) / 1048576, 1), "MB")
