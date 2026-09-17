"""The real screens as a clickable flow: each screen is the actual capture,
each control is a hotspot at its real bounds, taps go where the app goes.

    python3 build_html.py  ->  tiehere-ui-flow.html  (images in img/)
"""
import json
import os

from flow import AREAS, SCREENS, TABS, hotspots, HERE, W, H

data = {
    "areas": AREAS,
    "screens": [
        dict(id=s["id"], area=s["area"], title=s["title"], note=s["note"],
             hotspots=[h for h in hotspots(s) if h["rect"]])
        for s in SCREENS
    ],
    "w": W, "h": H,
}

TEMPLATE = r"""<title>TieHere UI Flow</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Condensed:wght@500;600;700&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root{--ground:#f4f6f5;--surface:#fff;--surface2:#eef1f3;--ink:#151b21;--muted:#5d6873;--hair:#d3dae0;--green:#34c24c;--blue:#2a6b90;--blue-soft:#e1edf4;--hot:rgba(42,107,144,.16);--hotline:rgba(42,107,144,.9);--shadow:0 14px 40px rgba(21,27,33,.14)}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--ground:#0f1318;--surface:#181d24;--surface2:#1f262e;--ink:#e8edf2;--muted:#9aa7b3;--hair:#2c353f;--green:#3fd15a;--blue:#a6d4ee;--blue-soft:#1b2f3c;--hot:rgba(166,212,238,.18);--hotline:rgba(166,212,238,.95);--shadow:0 14px 40px rgba(0,0,0,.5)}}
:root[data-theme="dark"]{--ground:#0f1318;--surface:#181d24;--surface2:#1f262e;--ink:#e8edf2;--muted:#9aa7b3;--hair:#2c353f;--green:#3fd15a;--blue:#a6d4ee;--blue-soft:#1b2f3c;--hot:rgba(166,212,238,.18);--hotline:rgba(166,212,238,.95);--shadow:0 14px 40px rgba(0,0,0,.5)}
*{box-sizing:border-box}
body{margin:0;background:var(--ground);color:var(--ink);font:14px/1.5 "IBM Plex Sans",system-ui,sans-serif}
.wrap{max-width:1400px;margin:0 auto;padding-block:18px 40px;padding-inline:16px}
h1,h2,h3{font-family:"IBM Plex Sans Condensed","Arial Narrow",sans-serif}
.mono{font-family:"IBM Plex Mono",ui-monospace,Menlo,monospace}
header.top{display:flex;flex-wrap:wrap;align-items:baseline;gap:8px 18px;margin-bottom:12px}
header.top h1{font-size:26px;margin:0}
header.top .sub{color:var(--muted);font-size:13px}
.views{margin-left:auto;display:flex;gap:6px}
.views button,.tog{font:600 12px/1 "IBM Plex Sans Condensed",sans-serif;letter-spacing:.6px;text-transform:uppercase;padding:9px 14px;border:1px solid var(--hair);background:var(--surface);color:var(--ink);border-radius:999px;cursor:pointer}
.views button[aria-pressed="true"],.tog[aria-pressed="true"]{background:var(--ink);color:var(--ground);border-color:var(--ink)}
button:focus-visible,[tabindex]:focus-visible{outline:2px solid var(--green);outline-offset:2px}
.trail{display:flex;flex-wrap:wrap;gap:6px;align-items:center;font-size:12px;color:var(--muted);margin:0 0 12px}
.trail b{color:var(--ink);font-weight:600}.trail .sep{opacity:.5}
.trail button{font:600 12px "IBM Plex Sans",sans-serif;color:var(--blue);background:transparent;border:0;cursor:pointer;padding:0 6px}
.grid{display:grid;grid-template-columns:240px minmax(0,1fr) 300px;gap:22px;align-items:start}
@media (max-width:1040px){.grid{grid-template-columns:1fr}.rail{order:3}.side{order:2}}
.rail{position:sticky;top:12px;max-height:calc(100vh - 24px);overflow:auto;padding-right:4px}
.rail h3{font-size:11px;letter-spacing:1.4px;text-transform:uppercase;color:var(--muted);margin:14px 0 6px}
.rail h3:first-child{margin-top:0}
.rail button{display:block;width:100%;text-align:left;font:500 12.5px/1.25 "IBM Plex Sans",sans-serif;color:var(--ink);background:transparent;border:0;border-left:3px solid transparent;padding:5px 8px;border-radius:0 6px 6px 0;cursor:pointer}
.rail button:hover{background:var(--surface)}
.rail button[aria-current="true"]{border-left-color:var(--green);background:var(--surface);font-weight:600}
@media (max-width:1040px){.rail{position:static;max-height:none;display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:0 14px}.rail h3{grid-column:1/-1}}
.stage{display:flex;flex-direction:column;align-items:center;gap:10px}
.screen-title{width:min(100%,420px);display:flex;flex-wrap:wrap;align-items:baseline;gap:8px 12px}
.screen-title h2{margin:0;font-size:20px}.screen-title .id{color:var(--muted);font-size:11px}
.note{width:min(100%,420px);font-size:12.5px;color:var(--muted);background:var(--surface);border:1px solid var(--hair);border-radius:10px;padding:8px 12px}
.phone{position:relative;width:min(100%,420px);aspect-ratio:1080/2400;border-radius:32px;overflow:hidden;box-shadow:var(--shadow);background:#000}
.phone img{display:block;width:100%;height:100%;object-fit:cover}
.hs{position:absolute;border:1.5px solid transparent;border-radius:8px;background:transparent;cursor:pointer;padding:0}
.hs:hover,.hs:focus-visible,.show .hs{border-color:var(--hotline);background:var(--hot)}
.hs .tag{position:absolute;left:0;top:100%;margin-top:3px;font:500 10px/1 "IBM Plex Mono",monospace;background:var(--ink);color:var(--ground);padding:4px 6px;border-radius:5px;white-space:nowrap;opacity:0;pointer-events:none;transform:translateY(-2px);transition:opacity .12s}
.hs:hover .tag,.hs:focus-visible .tag{opacity:1}
.hs.top .tag{top:auto;bottom:100%;margin:0 0 3px}
.side{position:sticky;top:12px;display:flex;flex-direction:column;gap:14px}
@media (max-width:1040px){.side{position:static}}
.panel{background:var(--surface);border:1px solid var(--hair);border-radius:14px;padding:12px 14px}
.panel h3{margin:0 0 8px;font-size:11px;letter-spacing:1.4px;text-transform:uppercase;color:var(--muted)}
.panel ul{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:6px}
.panel li{display:grid;grid-template-columns:1fr auto;gap:8px;align-items:baseline;font-size:12.5px}
.panel li .gate{color:var(--muted);font-size:11px}
.panel li button{font:600 12px "IBM Plex Sans",sans-serif;color:var(--blue);background:transparent;border:0;padding:0;cursor:pointer;text-align:right;white-space:nowrap}
.panel li button:hover{text-decoration:underline}
.panel .none{color:var(--muted);font-size:12px}
.legend{font-size:12px;color:var(--muted);line-height:1.5}.legend b{color:var(--ink)}
.map{overflow-x:auto;background:var(--surface);border:1px solid var(--hair);border-radius:14px;padding:12px}
.map svg{display:block}
.map .node{cursor:pointer}
.map .node image{border-radius:8px}
.map .node rect.fr{fill:none;stroke:var(--hair);rx:10}
.map .node.on rect.fr{stroke:var(--green);stroke-width:3}
.map text.t{fill:var(--ink);font:600 10px "IBM Plex Sans",sans-serif}
.map text.area{fill:var(--muted);font:600 12px "IBM Plex Sans Condensed",sans-serif;letter-spacing:1.2px}
.map path.e{fill:none;stroke:var(--blue);stroke-opacity:.3;stroke-width:1.2}
.map path.e.hot{stroke-opacity:1;stroke-width:2.2}.map path.e.dim{stroke-opacity:.06}
</style>
<div class="wrap">
  <header class="top">
    <h1>TieHere UI Flow</h1>
    <span class="sub">The real screens, captured 17 Sep 2026. Tap a control on the phone to go where the app goes.</span>
    <div class="views">
      <button class="tog" id="tog-hs" aria-pressed="false">Show hotspots</button>
      <button id="v-walk" aria-pressed="true">Walkthrough</button>
      <button id="v-map" aria-pressed="false">Map</button>
    </div>
  </header>
  <div id="walk">
    <div class="trail" id="trail"></div>
    <div class="grid">
      <nav class="rail" id="rail" aria-label="Screens"></nav>
      <div class="stage">
        <div class="screen-title" id="stitle"></div>
        <div class="phone" id="phone"></div>
        <div class="note" id="note" hidden></div>
      </div>
      <aside class="side">
        <div class="panel"><h3>Controls on this screen</h3><ul id="out"></ul></div>
        <div class="panel"><h3>Reached from</h3><ul id="in"></ul></div>
        <div class="panel legend"><b>Gates.</b> L0 guest sees only; L2 (phone, personal email, personal details, LinkedIn) can join and use SOS; L3 (organisation and work email) can host. Hotspots are the controls' real bounds from the accessibility tree; toggle <b>Show hotspots</b> to outline them.</div>
      </aside>
    </div>
  </div>
  <div id="mapview" hidden>
    <p class="legend" style="margin:0 0 10px">Every capture in its area, with each navigation drawn. Hover a screen to light its arrows; click to open it.</p>
    <div class="map" id="map"></div>
  </div>
</div>
<script>
const DATA = __DATA__;
const byId = Object.fromEntries(DATA.screens.map(s => [s.id, s]));
let current = '01-landing', trail = [], showHs = false;
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function go(id, via){ if (id === current) return; trail.push({from: current, via}); if (trail.length > 14) trail.shift(); current = id; render(); document.getElementById('phone').scrollIntoView({block:'nearest'}); }
function back(){ const l = trail.pop(); if (l){ current = l.from; render(); } }
function render(){
  const s = byId[current];
  document.getElementById('stitle').innerHTML = '<h2>' + esc(s.title) + '</h2><span class="id mono">' + esc(s.id) + '</span>';
  const note = document.getElementById('note'); note.hidden = !s.note; note.textContent = s.note || '';
  const ph = document.getElementById('phone'); ph.innerHTML = ''; ph.classList.toggle('show', showHs);
  const img = document.createElement('img'); img.src = 'img/' + s.id + '.jpg'; img.alt = s.title; ph.appendChild(img);
  s.hotspots.forEach(h => {
    const [x1,y1,x2,y2] = h.rect;
    const b = document.createElement('button'); b.className = 'hs' + (y1 / DATA.h > 0.85 ? ' top' : '');
    b.style.left = (x1/DATA.w*100) + '%'; b.style.top = (y1/DATA.h*100) + '%';
    b.style.width = ((x2-x1)/DATA.w*100) + '%'; b.style.height = ((y2-y1)/DATA.h*100) + '%';
    b.setAttribute('aria-label', h.label + ' → ' + byId[h.target].title);
    b.innerHTML = '<span class="tag">' + esc(h.label) + (h.gate ? '  · ' + esc(h.gate) : '') + '  →  ' + esc(byId[h.target].title) + '</span>';
    b.addEventListener('click', () => go(h.target, h.label));
    ph.appendChild(b);
  });
  const t = document.getElementById('trail');
  t.innerHTML = trail.map(x => '<span>' + esc(byId[x.from].title) + '</span><span class="sep">›</span>').join('') + '<b>' + esc(s.title) + '</b>' + (trail.length ? '<button id="backbtn">‹ back</button>' : '');
  const bb = document.getElementById('backbtn'); if (bb) bb.addEventListener('click', back);
  document.querySelectorAll('#rail button').forEach(b => b.setAttribute('aria-current', b.dataset.id === current ? 'true' : 'false'));
  const li = (lab, gate, id) => '<li><span>' + esc(lab) + (gate ? ' <span class="gate mono">' + esc(gate) + '</span>' : '') + '</span><button data-id="' + id + '">' + esc(byId[id].title) + ' ›</button></li>';
  const out = s.hotspots.filter(h => h.target !== s.id);
  document.getElementById('out').innerHTML = out.length ? out.map(h => li(h.label, h.gate, h.target)).join('') : '<li class="none">Only back from here.</li>';
  const inn = []; DATA.screens.forEach(o => o.hotspots.forEach(h => { if (h.target === s.id && o.id !== s.id && !h.label.endsWith(' tab')) inn.push([o, h]); }));
  document.getElementById('in').innerHTML = inn.length ? inn.map(([o,h]) => li(h.label, h.gate, o.id)).join('') : '<li class="none">Entry point, or reached by the tab bar.</li>';
  document.querySelectorAll('#out button, #in button').forEach(b => b.addEventListener('click', () => go(b.dataset.id, 'panel')));
  if (mapBuilt) highlightMap();
}
function buildRail(){
  const r = document.getElementById('rail');
  r.innerHTML = DATA.areas.map(([aid, title]) => '<h3>' + esc(title) + '</h3>' + DATA.screens.filter(s => s.area === aid).map(s => '<button data-id="' + s.id + '">' + esc(s.title) + '</button>').join('')).join('');
  r.querySelectorAll('button').forEach(b => b.addEventListener('click', () => go(b.dataset.id, 'list')));
}
let mapBuilt = false, pos = {};
function buildMap(){
  const tw = 96, th = Math.round(tw * DATA.h / DATA.w), gx = 26, gy = 30, top = 40, left = 16, perRow = 8;
  let svg = '', y = top, width = left + perRow * (tw + gx);
  DATA.areas.forEach(([aid, title]) => {
    const col = DATA.screens.filter(s => s.area === aid); if (!col.length) return;
    svg += '<text class="area" x="' + left + '" y="' + (y - 12) + '">' + esc(title.toUpperCase()) + '</text>';
    col.forEach((s, i) => { pos[s.id] = {x: left + (i % perRow) * (tw + gx), y: y + Math.floor(i / perRow) * (th + gy + 16), w: tw, h: th}; });
    y += Math.ceil(col.length / perRow) * (th + gy + 16) + 30;
  });
  let edges = '';
  DATA.screens.forEach(s => s.hotspots.forEach(h => {
    if (h.target === s.id || h.label.endsWith(' tab')) return;
    const a = pos[s.id], b = pos[h.target]; if (!a || !b) return;
    const x1 = a.x + a.w/2, y1 = a.y + a.h/2, x2 = b.x + b.w/2, y2 = b.y + b.h/2;
    const dx = (x2 - x1) * .3, dy = (y2 - y1) * .3;
    edges += '<path class="e" data-from="' + s.id + '" data-to="' + h.target + '" d="M' + x1 + ' ' + y1 + ' C ' + (x1 + dx) + ' ' + (y1 - 40) + ', ' + (x2 - dx) + ' ' + (y2 + 40) + ', ' + x2 + ' ' + y2 + '"><title>' + esc(s.title + '  →  ' + byId[h.target].title + '   ' + h.label + (h.gate ? ' · ' + h.gate : '')) + '</title></path>';
  }));
  let nodes = '';
  DATA.screens.forEach(s => { const p = pos[s.id]; nodes += '<g class="node" data-id="' + s.id + '" tabindex="0"><image href="img/' + s.id + '.jpg" x="' + p.x + '" y="' + p.y + '" width="' + p.w + '" height="' + p.h + '" preserveAspectRatio="xMidYMid slice"/><rect class="fr" x="' + p.x + '" y="' + p.y + '" width="' + p.w + '" height="' + p.h + '"/><text class="t" x="' + p.x + '" y="' + (p.y + p.h + 12) + '">' + esc(s.title.slice(0, 20)) + '</text></g>'; });
  const m = document.getElementById('map');
  m.innerHTML = '<svg viewBox="0 0 ' + width + ' ' + y + '" width="' + width + '" height="' + y + '"><defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#2a6b90"/></marker></defs>' + edges + nodes + '</svg>';
  m.querySelectorAll('.node').forEach(n => { n.addEventListener('mouseenter', () => highlightMap(n.dataset.id)); n.addEventListener('mouseleave', () => highlightMap()); n.addEventListener('click', () => { setView('walk'); go(n.dataset.id, 'map'); }); n.addEventListener('keydown', e => { if (e.key === 'Enter'){ setView('walk'); go(n.dataset.id, 'map'); } }); });
  mapBuilt = true;
}
function highlightMap(hover){ const id = hover || current; document.querySelectorAll('#map .node').forEach(n => n.classList.toggle('on', n.dataset.id === id)); document.querySelectorAll('#map path.e').forEach(p => { const hot = p.dataset.from === id || p.dataset.to === id; p.classList.toggle('hot', hot); p.classList.toggle('dim', hover ? !hot : false); if (hot) p.setAttribute('marker-end', 'url(#ah)'); else p.removeAttribute('marker-end'); }); }
function setView(v){ document.getElementById('walk').hidden = v !== 'walk'; document.getElementById('mapview').hidden = v !== 'map'; document.getElementById('v-walk').setAttribute('aria-pressed', v === 'walk'); document.getElementById('v-map').setAttribute('aria-pressed', v === 'map'); if (v === 'map'){ if (!mapBuilt) buildMap(); highlightMap(); } }
document.getElementById('v-walk').addEventListener('click', () => setView('walk'));
document.getElementById('v-map').addEventListener('click', () => setView('map'));
document.getElementById('tog-hs').addEventListener('click', e => { showHs = !showHs; e.currentTarget.setAttribute('aria-pressed', showHs); document.getElementById('phone').classList.toggle('show', showHs); });
buildRail(); render();
</script>
"""

html = TEMPLATE.replace("__DATA__", json.dumps(data, ensure_ascii=False))
with open(os.path.join(HERE, "tiehere-ui-flow.html"), "w") as f:
    f.write(html)
print(len(SCREENS), "screens,", sum(len(s["hotspots"]) for s in data["screens"]), "hotspots,", len(html) // 1024, "KB")
