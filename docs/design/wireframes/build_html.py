"""Renders screens.py as a clickable wireframe flow (one HTML file).

    python3 build_html.py  ->  tiehere-flow.html

Tap a control on a wireframe and you land where the app would; gated
controls show their branches. The Map view draws every screen and arrow.
"""
import json

from screens import AREAS, SCREENS, NAV, NAV_TARGETS, edges

data = {
    "areas": AREAS,
    "nav": NAV,
    "navTargets": NAV_TARGETS,
    "screens": SCREENS,
    "edges": edges(),
}

TEMPLATE = r"""<title>TieHere Wireframes</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Condensed:wght@500;600;700&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root{
  --ground:#f4f6f5; --surface:#ffffff; --surface2:#eef1f3; --ink:#151b21; --muted:#5d6873;
  --hair:#d3dae0; --green:#34c24c; --green-soft:#e3f6e7; --blue:#2a6b90; --blue-soft:#e1edf4;
  --note:#fff6d1; --note-ink:#5a4d10; --note-edge:#e8d98f; --frame:#0f1318; --shadow:0 10px 30px rgba(21,27,33,.10);
  --sheet:#eef1f3;
}
@media (prefers-color-scheme: dark){ :root:not([data-theme="light"]){
  --ground:#0f1318; --surface:#181d24; --surface2:#1f262e; --ink:#e8edf2; --muted:#9aa7b3;
  --hair:#2c353f; --green:#3fd15a; --green-soft:#173a20; --blue:#a6d4ee; --blue-soft:#1b2f3c;
  --note:#2a2717; --note-ink:#e6d58a; --note-edge:#4a4320; --frame:#3a4550; --shadow:0 10px 30px rgba(0,0,0,.45);
  --sheet:#1f262e;
}}
:root[data-theme="dark"]{
  --ground:#0f1318; --surface:#181d24; --surface2:#1f262e; --ink:#e8edf2; --muted:#9aa7b3;
  --hair:#2c353f; --green:#3fd15a; --green-soft:#173a20; --blue:#a6d4ee; --blue-soft:#1b2f3c;
  --note:#2a2717; --note-ink:#e6d58a; --note-edge:#4a4320; --frame:#3a4550; --shadow:0 10px 30px rgba(0,0,0,.45);
  --sheet:#1f262e;
}
*{box-sizing:border-box}
body{margin:0;background:var(--ground);color:var(--ink);font:14px/1.5 "IBM Plex Sans",system-ui,-apple-system,"Segoe UI",sans-serif}
.wrap{max-width:1380px;margin:0 auto;padding-block:18px 40px;padding-inline:16px}
h1,h2,h3,.cond{font-family:"IBM Plex Sans Condensed","Arial Narrow",system-ui,sans-serif}
.mono{font-family:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace}
header.top{display:flex;flex-wrap:wrap;align-items:baseline;gap:8px 18px;margin-bottom:14px}
header.top h1{font-size:26px;margin:0;letter-spacing:.2px}
header.top .sub{color:var(--muted);font-size:13px}
.views{margin-left:auto;display:flex;gap:6px}
.views button{font:600 12px/1 "IBM Plex Sans Condensed",sans-serif;letter-spacing:.6px;text-transform:uppercase;padding:9px 14px;border:1px solid var(--hair);background:var(--surface);color:var(--ink);border-radius:999px;cursor:pointer}
.views button[aria-pressed="true"]{background:var(--ink);color:var(--ground);border-color:var(--ink)}
.views button:focus-visible,button:focus-visible,[tabindex]:focus-visible{outline:2px solid var(--green);outline-offset:2px}

.trail{display:flex;flex-wrap:wrap;gap:6px;align-items:center;font-size:12px;color:var(--muted);margin:0 0 14px}
.trail b{color:var(--ink);font-weight:600}
.trail .sep{opacity:.5}

.grid{display:grid;grid-template-columns:230px minmax(0,1fr) 300px;gap:22px;align-items:start}
@media (max-width:1000px){.grid{grid-template-columns:1fr}.rail{order:3}.side{order:2}}

/* rail */
.rail{position:sticky;top:12px;max-height:calc(100vh - 24px);overflow:auto;padding-right:4px}
.rail h3{font-size:11px;letter-spacing:1.4px;text-transform:uppercase;color:var(--muted);margin:14px 0 6px}
.rail h3:first-child{margin-top:0}
.rail button{display:block;width:100%;text-align:left;font:500 13px/1.25 "IBM Plex Sans",sans-serif;color:var(--ink);background:transparent;border:0;border-left:3px solid transparent;padding:6px 8px;border-radius:0 6px 6px 0;cursor:pointer}
.rail button:hover{background:var(--surface)}
.rail button[aria-current="true"]{border-left-color:var(--green);background:var(--surface);font-weight:600}
@media (max-width:1000px){.rail{position:static;max-height:none;display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:0 14px}.rail h3{grid-column:1/-1}}

/* phone */
.stage{display:flex;flex-direction:column;align-items:center;gap:12px}
.phone{width:min(100%,372px);background:var(--surface);border:2px solid var(--frame);border-radius:34px;box-shadow:var(--shadow);padding:22px 14px 14px;position:relative}
.phone:before{content:"";position:absolute;left:50%;top:9px;transform:translateX(-50%);width:76px;height:5px;border-radius:3px;background:var(--frame);opacity:.6}
.screen-title{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;width:min(100%,372px)}
.screen-title h2{margin:0;font-size:20px}
.screen-title .file{color:var(--muted);font-size:11px}
.items{display:flex;flex-direction:column;gap:8px}

.bar{display:flex;align-items:center;gap:10px;padding-bottom:8px;border-bottom:1px solid var(--hair);font-family:"IBM Plex Sans Condensed",sans-serif;font-weight:700;font-size:13px;letter-spacing:1.2px}
.bar .back{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;background:var(--surface2);font-size:16px;cursor:pointer;border:0;color:var(--ink)}
.h{font-family:"IBM Plex Sans Condensed",sans-serif;font-size:19px;font-weight:700;line-height:1.2;text-wrap:balance;margin:4px 0}
.p{color:var(--muted);font-size:12.5px;line-height:1.45}
.p.label{font-size:10.5px;letter-spacing:1.6px;font-weight:600;text-transform:uppercase;margin-top:6px}
.btn,.sec,.link{display:block;width:100%;font:700 12px/1.2 "IBM Plex Sans Condensed",sans-serif;letter-spacing:1px;text-transform:uppercase;border-radius:16px;padding:12px 14px;text-align:center;cursor:pointer;border:1.5px solid transparent}
.btn{background:var(--green);color:#0b1a0f}
.sec{background:transparent;color:var(--blue);border-color:var(--blue)}
.link{background:transparent;color:var(--blue);text-transform:none;letter-spacing:.2px;padding:6px}
.btn:not(.go),.sec:not(.go),.link:not(.go){cursor:default;opacity:.85}
.go{position:relative}
.go:hover{filter:brightness(1.05)}
.go:after{content:"›";position:absolute;right:12px;top:50%;transform:translateY(-50%);font-size:16px;opacity:.7}
.go.multi:after{content:"⑂"}
.input{border:1px solid var(--hair);border-radius:10px;padding:10px 12px;color:var(--muted);font-size:12.5px;background:var(--surface)}
.otp{display:grid;grid-template-columns:repeat(6,1fr);gap:6px}
.otp span{aspect-ratio:1/1.15;border:1px solid var(--hair);border-radius:8px;background:var(--surface)}
.check{display:flex;gap:10px;align-items:flex-start;font-size:12.5px}
.check i{flex:none;width:16px;height:16px;border:1.5px solid var(--ink);border-radius:4px;margin-top:2px}
.tabs{display:flex;flex-wrap:wrap;gap:4px 12px;font:700 11px/1 "IBM Plex Sans Condensed",sans-serif;letter-spacing:1px;text-transform:uppercase;color:var(--muted)}
.tabs span{padding:6px 0 7px;border-bottom:3px solid transparent}
.tabs span.on{color:var(--green);border-bottom-color:var(--green)}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chips span{border:1px solid var(--hair);border-radius:999px;padding:4px 10px;font-size:11px}
.card{border:1px solid var(--hair);border-left:4px solid var(--green);border-radius:12px;padding:10px 12px;display:flex;flex-direction:column;gap:3px;background:var(--surface2)}
.card b{font-size:12.5px}
.card span{font-size:11.5px;color:var(--muted)}
.card.go{cursor:pointer}
.row{display:flex;align-items:center;gap:10px;border:1px solid var(--hair);border-radius:12px;padding:9px 12px;background:var(--surface)}
.row .t{flex:1;min-width:0}
.row b{display:block;font-size:12.5px}
.row span{display:block;font-size:11px;color:var(--muted)}
.row .chev{color:var(--muted);font-size:18px}
.row.go{cursor:pointer}
.row.go:hover{border-color:var(--blue)}
.state{background:var(--note);color:var(--note-ink);border:1px solid var(--note-edge);border-radius:8px;padding:7px 10px;font-size:11px;line-height:1.4}
.sheet{background:var(--sheet);border:1px solid var(--hair);border-radius:18px 18px 12px 12px;padding:10px 12px 12px;display:flex;flex-direction:column;gap:8px;margin:0 -4px}
.sheet:before{content:"";display:block;width:36px;height:4px;border-radius:2px;background:var(--hair);margin:0 auto 2px}
.sheet .stitle{font-size:10.5px;letter-spacing:1.6px;font-weight:600;color:var(--muted)}
.nav{display:grid;grid-template-columns:repeat(4,1fr);border-top:1px solid var(--hair);margin:6px -14px -14px;padding:10px 0 8px;background:var(--surface);border-radius:0 0 30px 30px}
.nav button{font:700 9.5px/1 "IBM Plex Sans Condensed",sans-serif;letter-spacing:1.4px;background:transparent;border:0;color:var(--muted);padding:8px 0;cursor:pointer}
.nav button.on{color:var(--blue)}

/* branch chooser */
.pick{position:absolute;z-index:5;background:var(--surface);border:1px solid var(--hair);border-radius:12px;box-shadow:var(--shadow);padding:6px;min-width:220px;max-width:300px}
.pick h4{margin:4px 8px 6px;font-size:11px;letter-spacing:1.2px;text-transform:uppercase;color:var(--muted);font-weight:600}
.pick button{display:flex;width:100%;justify-content:space-between;gap:12px;align-items:center;text-align:left;font:13px/1.3 "IBM Plex Sans",sans-serif;background:transparent;border:0;color:var(--ink);padding:8px 10px;border-radius:8px;cursor:pointer}
.pick button:hover{background:var(--surface2)}
.pick .cond{font-size:12px;color:var(--muted)}
.pick .to{font-weight:600;color:var(--blue);white-space:nowrap}

/* side */
.side{position:sticky;top:12px;display:flex;flex-direction:column;gap:14px}
@media (max-width:1000px){.side{position:static}}
.panel{background:var(--surface);border:1px solid var(--hair);border-radius:14px;padding:12px 14px}
.panel h3{margin:0 0 8px;font-size:11px;letter-spacing:1.4px;text-transform:uppercase;color:var(--muted)}
.panel ul{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:6px}
.panel li{display:grid;grid-template-columns:1fr auto;gap:8px;align-items:baseline;font-size:12.5px}
.panel li .lab{color:var(--ink)}
.panel li .gate{color:var(--muted);font-size:11px}
.panel li button{font:600 12px "IBM Plex Sans",sans-serif;color:var(--blue);background:transparent;border:0;padding:0;cursor:pointer;text-align:right;white-space:nowrap}
.panel li button:hover{text-decoration:underline}
.panel .none{color:var(--muted);font-size:12px}
.legend{font-size:12px;color:var(--muted);line-height:1.5}
.legend b{color:var(--ink)}

/* map */
.map{overflow-x:auto;background:var(--surface);border:1px solid var(--hair);border-radius:14px;padding:10px}
.map svg{display:block;font-family:"IBM Plex Sans",sans-serif}
.map .node rect{fill:var(--surface2);stroke:var(--hair);rx:8}
.map .node text{fill:var(--ink);font-size:11px;font-weight:600}
.map .node.on rect{stroke:var(--green);stroke-width:2}
.map .node{cursor:pointer}
.map .col text.area{fill:var(--muted);font-size:11px;letter-spacing:1.2px;font-weight:600}
.map path.e{fill:none;stroke:var(--blue);stroke-opacity:.35;stroke-width:1.2}
.map path.e.hot{stroke-opacity:1;stroke-width:2}
.map path.e.dim{stroke-opacity:.08}
.map text.gate{fill:var(--muted);font-size:9px;font-family:"IBM Plex Mono",monospace}
@media (prefers-reduced-motion:no-preference){.phone{transition:opacity .15s}}
</style>

<div class="wrap">
  <header class="top">
    <h1>TieHere Wireframes</h1>
    <span class="sub">Every screen and every tap, read off the Flutter code on 17 Sep 2026. Tap a control to follow it.</span>
    <div class="views" role="tablist">
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
      </div>
      <aside class="side">
        <div class="panel"><h3>Where each control goes</h3><ul id="out"></ul></div>
        <div class="panel"><h3>Reached from</h3><ul id="in"></ul></div>
        <div class="panel legend"><b>Gates.</b> L0 guest sees only; L2 (phone, personal email, personal details) can join and use SOS; L3 (organisation and work email) can host. Ride share and dating are marked coming soon. <b>Yellow notes</b> describe other states of the same screen. <b>⑂</b> marks a control with more than one destination.</div>
      </aside>
    </div>
  </div>

  <div id="mapview" hidden>
    <p class="legend" style="margin:0 0 10px">Columns are the app's areas; each arrow is a Navigator push in the code. Hover a screen to light its arrows; click to open it in the walkthrough.</p>
    <div class="map" id="map"></div>
  </div>
</div>

<script>
const DATA = __DATA__;
const byId = Object.fromEntries(DATA.screens.map(s => [s.id, s]));
let current = 'landing';
let trail = [];

function esc(s){return String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function targetsOf(it){
  const k = it[0];
  if (k === 'btn' || k === 'sec' || k === 'link'){ const t = it[2]; if (Array.isArray(t)) return t.map(([c,id]) => ({cond:c,id})); if (t) return [{cond:'',id:t}]; }
  if (k === 'card' && it[2]) return [{cond:'',id:it[2]}];
  if (k === 'row' && it[3]) return [{cond:'',id:it[3]}];
  return [];
}

let pick = null;
function closePick(){ if (pick){ pick.remove(); pick = null; } }
document.addEventListener('click', e => { if (pick && !pick.contains(e.target)) closePick(); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') closePick(); });

function go(id, via){
  closePick();
  if (id === current) return;
  trail.push({from: current, via});
  if (trail.length > 12) trail.shift();
  current = id;
  render();
  document.getElementById('phone').scrollIntoView({block:'nearest'});
}

function attach(el, it, label){
  const ts = targetsOf(it);
  if (!ts.length) return;
  el.classList.add('go');
  if (ts.length > 1) el.classList.add('multi');
  el.tabIndex = 0;
  el.setAttribute('role','button');
  const open = ev => {
    ev.stopPropagation();
    if (ts.length === 1){ go(ts[0].id, label); return; }
    closePick();
    pick = document.createElement('div');
    pick.className = 'pick';
    pick.innerHTML = '<h4>' + esc(label) + '</h4>' + ts.map(t =>
      '<button data-id="' + t.id + '"><span class="cond">' + esc(t.cond) + '</span><span class="to">' + esc(byId[t.id].title) + ' ›</span></button>').join('');
    pick.querySelectorAll('button').forEach(b => b.addEventListener('click', e => { e.stopPropagation(); go(b.dataset.id, label + ' (' + b.querySelector('.cond').textContent + ')'); }));
    const ph = document.getElementById('phone');
    ph.appendChild(pick);
    const r = el.getBoundingClientRect(), pr = ph.getBoundingClientRect();
    pick.style.left = Math.max(8, Math.min(r.left - pr.left, pr.width - 240)) + 'px';
    pick.style.top = (r.bottom - pr.top + 4) + 'px';
  };
  el.addEventListener('click', open);
  el.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(e); } });
}

function itemNode(it){
  const k = it[0];
  let el;
  if (k === 'bar'){ el = document.createElement('div'); el.className = 'bar'; el.innerHTML = '<button class="back" aria-label="Back">‹</button><span>' + esc(it[1]) + '</span>'; el.querySelector('.back').addEventListener('click', () => back()); }
  else if (k === 'h'){ el = document.createElement('div'); el.className = 'h'; el.textContent = it[1]; }
  else if (k === 'p'){ el = document.createElement('div'); el.className = 'p' + (it[1] === it[1].toUpperCase() && /[A-Z]/.test(it[1]) ? ' label' : ''); el.textContent = it[1]; }
  else if (k === 'btn' || k === 'sec' || k === 'link'){ el = document.createElement('div'); el.className = k; el.textContent = it[1]; attach(el, it, it[1]); }
  else if (k === 'input'){ el = document.createElement('div'); el.className = 'input'; el.textContent = it[1]; }
  else if (k === 'otp'){ el = document.createElement('div'); el.className = 'otp'; el.innerHTML = '<span></span>'.repeat(6); }
  else if (k === 'check'){ el = document.createElement('div'); el.className = 'check'; el.innerHTML = '<i></i><span>' + esc(it[1]) + '</span>'; }
  else if (k === 'tabs'){ el = document.createElement('div'); el.className = 'tabs'; el.innerHTML = it[1].map((l,i) => '<span class="' + (i === it[2] ? 'on' : '') + '">' + esc(l) + '</span>').join(''); }
  else if (k === 'chips'){ el = document.createElement('div'); el.className = 'chips'; el.innerHTML = it[1].map(l => '<span>' + esc(l) + '</span>').join(''); }
  else if (k === 'card'){ el = document.createElement('div'); el.className = 'card'; el.innerHTML = it[1].map((l,i) => (i ? '<span>' : '<b>') + esc(l) + (i ? '</span>' : '</b>')).join(''); attach(el, it, 'card'); }
  else if (k === 'row'){ el = document.createElement('div'); el.className = 'row'; el.innerHTML = '<div class="t"><b>' + esc(it[1]) + '</b>' + (it[2] ? '<span>' + esc(it[2]) + '</span>' : '') + '</div><span class="chev">›</span>'; attach(el, it, it[1]); }
  else if (k === 'state'){ el = document.createElement('div'); el.className = 'state'; el.textContent = it[1]; }
  else if (k === 'sheet'){ el = document.createElement('div'); el.className = 'sheet'; const t = document.createElement('div'); t.className = 'stitle'; t.textContent = it[1]; el.appendChild(t); it[2].forEach(s => el.appendChild(itemNode(s))); }
  else if (k === 'nav'){ el = document.createElement('div'); el.className = 'nav'; DATA.nav.forEach((l,i) => { const b = document.createElement('button'); b.textContent = l; if (i === it[1]) b.className = 'on'; b.addEventListener('click', () => go(DATA.navTargets[i], l + ' tab')); el.appendChild(b); }); }
  return el;
}

function back(){ const last = trail.pop(); if (last){ current = last.from; render(); } }

function render(){
  const s = byId[current];
  document.getElementById('stitle').innerHTML = '<h2>' + esc(s.title) + '</h2><span class="file mono">frontend/lib/features/' + esc(s.file) + '</span>';
  const ph = document.getElementById('phone');
  ph.innerHTML = '';
  const items = document.createElement('div'); items.className = 'items';
  s.items.forEach(it => items.appendChild(itemNode(it)));
  ph.appendChild(items);

  // trail
  const t = document.getElementById('trail');
  const parts = trail.map(x => '<span>' + esc(byId[x.from].title) + '</span><span class="sep">›</span>');
  t.innerHTML = parts.join('') + '<b>' + esc(s.title) + '</b>' + (trail.length ? ' <button class="link" style="width:auto;display:inline;padding:0 6px" id="backbtn">‹ back</button>' : '');
  const bb = document.getElementById('backbtn'); if (bb) bb.addEventListener('click', back);

  // rail
  document.querySelectorAll('#rail button').forEach(b => b.setAttribute('aria-current', b.dataset.id === current ? 'true' : 'false'));

  // out / in
  const out = DATA.edges.filter(e => e[0] === current);
  const inn = DATA.edges.filter(e => e[1] === current);
  const li = (lab, gate, id) => '<li><span class="lab">' + esc(lab) + (gate ? ' <span class="gate mono">' + esc(gate) + '</span>' : '') + '</span><button data-id="' + id + '">' + esc(byId[id].title) + ' ›</button></li>';
  const split = l => { const i = l.indexOf('  ·  '); return i < 0 ? [l, ''] : [l.slice(0, i), l.slice(i + 5)]; };
  document.getElementById('out').innerHTML = out.length ? out.map(e => { const [lab, gate] = split(e[2]); return li(lab, gate, e[1]); }).join('') : '<li class="none">Nothing leaves from here except back.</li>';
  document.getElementById('in').innerHTML = inn.length ? inn.map(e => { const [lab, gate] = split(e[2]); return li(lab + (gate ? '' : ''), gate, e[0]).replace('</button>', '</button>'); }).join('') : '<li class="none">Entry point.</li>';
  document.querySelectorAll('#out button, #in button').forEach(b => b.addEventListener('click', () => go(b.dataset.id, 'panel')));
  if (mapBuilt) highlightMap();
}

function buildRail(){
  const r = document.getElementById('rail');
  r.innerHTML = DATA.areas.map(([aid, title]) => '<h3>' + esc(title) + '</h3>' + DATA.screens.filter(s => s.area === aid).map(s => '<button data-id="' + s.id + '">' + esc(s.title) + '</button>').join('')).join('');
  r.querySelectorAll('button').forEach(b => b.addEventListener('click', () => go(b.dataset.id, 'list')));
}

// ---- map
let mapBuilt = false, nodePos = {};
function buildMap(){
  const colW = 250, nodeH = 34, nodeW = 200, gapY = 14, top = 40, left = 20;
  const cols = DATA.areas.map(([aid]) => DATA.screens.filter(s => s.area === aid));
  const height = top + Math.max(...cols.map(c => c.length)) * (nodeH + gapY) + 20;
  const width = left + cols.length * colW;
  let svg = '<svg viewBox="0 0 ' + width + ' ' + height + '" width="' + width + '" height="' + height + '">';
  svg += '<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#2a6b90"/></marker></defs>';
  cols.forEach((col, ci) => {
    const x = left + ci * colW;
    svg += '<g class="col"><text class="area" x="' + x + '" y="' + (top - 16) + '">' + esc(DATA.areas[ci][1].toUpperCase()) + '</text></g>';
    col.forEach((s, ri) => { nodePos[s.id] = {x, y: top + ri * (nodeH + gapY), w: nodeW, h: nodeH}; });
  });
  // edges first (under nodes)
  DATA.edges.forEach((e, i) => {
    const a = nodePos[e[0]], b = nodePos[e[1]];
    if (!a || !b) return;
    const same = a.x === b.x;
    const x1 = same ? a.x + a.w : (b.x > a.x ? a.x + a.w : a.x), y1 = a.y + a.h / 2;
    const x2 = same ? b.x + b.w : (b.x > a.x ? b.x : b.x + b.w), y2 = b.y + b.h / 2;
    const dx = same ? 46 : Math.max(40, Math.abs(x2 - x1) * .4) * (x2 > x1 ? 1 : -1);
    const d = same ? 'M' + x1 + ' ' + y1 + ' C ' + (x1 + dx) + ' ' + y1 + ', ' + (x2 + dx) + ' ' + y2 + ', ' + x2 + ' ' + y2
                   : 'M' + x1 + ' ' + y1 + ' C ' + (x1 + dx) + ' ' + y1 + ', ' + (x2 - dx) + ' ' + y2 + ', ' + x2 + ' ' + y2;
    svg += '<path class="e" data-from="' + e[0] + '" data-to="' + e[1] + '" d="' + d + '" marker-end="url(#ah)"><title>' + esc(byId[e[0]].title + '  →  ' + byId[e[1]].title + '   ' + e[2]) + '</title></path>';
  });
  DATA.screens.forEach(s => {
    const p = nodePos[s.id];
    svg += '<g class="node" data-id="' + s.id + '" tabindex="0"><rect x="' + p.x + '" y="' + p.y + '" width="' + p.w + '" height="' + p.h + '"/><text x="' + (p.x + 10) + '" y="' + (p.y + 21) + '">' + esc(s.title) + '</text></g>';
  });
  svg += '</svg>';
  const m = document.getElementById('map');
  m.innerHTML = svg;
  m.querySelectorAll('.node').forEach(n => {
    n.addEventListener('mouseenter', () => highlightMap(n.dataset.id));
    n.addEventListener('mouseleave', () => highlightMap());
    n.addEventListener('click', () => { setView('walk'); go(n.dataset.id, 'map'); });
    n.addEventListener('keydown', e => { if (e.key === 'Enter') { setView('walk'); go(n.dataset.id, 'map'); } });
  });
  mapBuilt = true;
}
function highlightMap(hover){
  const id = hover || current;
  document.querySelectorAll('#map .node').forEach(n => n.classList.toggle('on', n.dataset.id === id));
  document.querySelectorAll('#map path.e').forEach(p => {
    const hot = p.dataset.from === id || p.dataset.to === id;
    p.classList.toggle('hot', hot);
    p.classList.toggle('dim', hover ? !hot : false);
  });
}
function setView(v){
  document.getElementById('walk').hidden = v !== 'walk';
  document.getElementById('mapview').hidden = v !== 'map';
  document.getElementById('v-walk').setAttribute('aria-pressed', v === 'walk');
  document.getElementById('v-map').setAttribute('aria-pressed', v === 'map');
  if (v === 'map'){ if (!mapBuilt) buildMap(); highlightMap(); }
}
document.getElementById('v-walk').addEventListener('click', () => setView('walk'));
document.getElementById('v-map').addEventListener('click', () => setView('map'));

buildRail();
render();
</script>
"""

html = TEMPLATE.replace("__DATA__", json.dumps(data, ensure_ascii=False))
with open("tiehere-flow.html", "w") as f:
    f.write(html)
print(f"{len(SCREENS)} screens, {len(data['edges'])} edges, {len(html)//1024} KB")
