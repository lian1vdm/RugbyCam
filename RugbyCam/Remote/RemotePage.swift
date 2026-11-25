import Foundation

/// The control panel page that the iPad opens in Safari.
enum RemotePage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>RugbyCam Remote</title>
<style>
:root { --bg:#0b1410; --panel:#14221b; --line:#243a2e; --text:#eef3ef; --dim:#9fb2a6;
        --gold:#f6b620; --green:#2fb36b; --red:#e5484d; }
* { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
html,body { margin:0; height:100%; background:var(--bg); color:var(--text);
            font:16px -apple-system, system-ui, sans-serif; -webkit-user-select:none; user-select:none; }
#app { display:flex; gap:14px; padding:14px; height:100%; }
#left { flex:1 1 auto; display:flex; flex-direction:column; gap:10px; min-width:0; }
#view { position:relative; width:100%; aspect-ratio:16/9; background:#000; border-radius:12px; overflow:hidden; }
#view img, #view canvas { position:absolute; inset:0; width:100%; height:100%; }
#view img { object-fit:contain; }
#paused { position:absolute; inset:0; display:none; align-items:center; justify-content:center;
          color:var(--dim); font-size:18px; text-align:center; padding:20px; }
#chips { display:flex; flex-wrap:wrap; gap:8px; }
.chip { background:var(--panel); border:1px solid var(--line); border-radius:999px; padding:6px 12px; font-size:14px; }
.chip.red { background:var(--red); border-color:var(--red); }
.chip.warn { color:var(--gold); border-color:var(--gold); }
#tracking { color:var(--dim); font-size:14px; }
#right { flex:0 0 300px; display:flex; flex-direction:column; gap:12px; }
button { font:inherit; color:var(--text); background:var(--panel); border:1px solid var(--line);
         border-radius:14px; padding:16px; font-size:18px; font-weight:600; width:100%; }
button:active { transform:scale(0.98); }
button.on { background:var(--green); border-color:var(--green); color:#04140b; }
#rec { background:var(--red); border-color:var(--red); font-size:22px; padding:22px; }
#rec.stop { background:#fff; color:var(--red); }
.row { display:flex; gap:10px; }
.row button { flex:1; }
.box { background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:14px; }
.label { color:var(--dim); font-size:13px; margin-bottom:8px; display:flex; justify-content:space-between; }
input[type=range] { width:100%; height:36px; accent-color:var(--gold); }
#notice { color:var(--gold); font-size:14px; min-height:18px; }
#conn { font-size:13px; color:var(--dim); }
#pinbox { position:fixed; inset:0; background:rgba(0,0,0,.85); display:none; align-items:center; justify-content:center; }
#pinbox .box { width:320px; text-align:center; }
input { -webkit-user-select:text; user-select:text; }
#pinmsg { color:var(--gold); font-size:14px; min-height:18px; margin-bottom:10px; }
#pinbox input { font:inherit; font-size:32px; letter-spacing:12px; width:100%; text-align:center; margin:14px 0;
                background:#000; color:var(--text); border:1px solid var(--line); border-radius:10px; padding:10px; }
#setbtn { font-size:16px; padding:12px; }
.pad { display:grid; grid-template-columns:repeat(3,1fr); gap:8px; }
.pad button { padding:14px 0; font-size:22px; touch-action:none; -webkit-touch-callout:none; }
.pad button.held { background:var(--gold); color:#000; }
.pad .mid { display:flex; align-items:center; justify-content:center; color:var(--dim); font-size:12px; text-align:center; }
#score { display:grid; grid-template-columns:1fr auto 1fr; gap:12px; align-items:start; }
.team { background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:12px; }
.team input { font:inherit; font-weight:700; color:var(--text); background:transparent; border:none; border-bottom:1px solid var(--line);
              width:100%; padding:4px 0; font-size:17px; }
.team .pts { font-size:46px; font-weight:800; font-variant-numeric:tabular-nums; margin:6px 0; }
.team.home .pts { color:var(--gold); }
.team.away .pts { color:var(--green); }
.team .btns { display:grid; grid-template-columns:repeat(4,1fr); gap:6px; }
.team .btns button { padding:10px 0; font-size:14px; }
.clock { text-align:center; padding-top:10px; }
.clock .t { font-size:30px; font-weight:800; font-variant-numeric:tabular-nums; }
.clock button { padding:8px 10px; font-size:13px; margin-top:8px; }
.clock button.on { background:var(--green); border-color:var(--green); color:#04140b; }
#sheet { position:fixed; inset:0; background:rgba(0,0,0,.6); display:none; justify-content:flex-end; }
#sheet .panel { width:min(520px,100%); height:100%; background:var(--bg); border-left:1px solid var(--line);
                overflow-y:auto; -webkit-overflow-scrolling:touch; padding:16px 16px 40px; }
#sheet .top { display:flex; justify-content:space-between; align-items:center; position:sticky; top:-16px;
              background:var(--bg); padding:10px 0; z-index:2; }
#sheet .top h2 { margin:0; font-size:20px; }
#sheet .top button { width:auto; padding:10px 18px; font-size:16px; }
#seterr { color:var(--gold); font-size:14px; min-height:18px; }
.sec { margin:18px 0 6px; color:var(--dim); font-size:13px; text-transform:uppercase; letter-spacing:.06em; }
.item { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:12px 14px; margin-bottom:8px; }
.item .head { display:flex; justify-content:space-between; gap:10px; align-items:center; }
.item .val { color:var(--gold); font-variant-numeric:tabular-nums; }
.item select, .item input[type=text] { font:inherit; color:var(--text); background:#000; border:1px solid var(--line);
                                        border-radius:8px; padding:8px; max-width:60%; }
.item input[type=text] { max-width:100%; width:100%; margin-top:8px; }
.item.off { opacity:.45; pointer-events:none; }
.switch { position:relative; width:52px; height:30px; flex:none; }
.switch input { opacity:0; width:0; height:0; }
.switch span { position:absolute; inset:0; background:#33443b; border-radius:30px; transition:.2s; }
.switch span:before { content:""; position:absolute; width:24px; height:24px; left:3px; top:3px; background:#fff; border-radius:50%; transition:.2s; }
.switch input:checked + span { background:var(--green); }
.switch input:checked + span:before { transform:translateX(22px); }
.note { color:var(--dim); font-size:13px; margin-top:6px; }
@media (max-width: 820px) { #app { flex-direction:column; height:auto; } #right { flex:none; } }
</style>
</head>
<body>
<div id="app">
  <div id="left">
    <div id="view">
      <img id="img" alt="">
      <canvas id="ov"></canvas>
      <div id="paused">The camera is paused because the settings are open on the iPhone.</div>
    </div>
    <div id="chips"></div>
    <div id="tracking"></div>
    <div id="notice"></div>
    <div id="score">
      <div class="team home">
        <input id="homeName" maxlength="16" autocomplete="off">
        <div class="pts" id="homeScore">0</div>
        <div class="btns">
          <button data-team="Home" data-p="5">Try +5</button><button data-team="Home" data-p="2">Conv +2</button>
          <button data-team="Home" data-p="3">Pen +3</button><button data-team="Home" data-p="-1">−1</button>
        </div>
      </div>
      <div class="clock">
        <div class="t" id="gameTime">00:00</div>
        <div id="periodText" style="color:var(--dim);font-size:13px">1st half</div>
        <button id="periodBtn">Change half</button><br>
        <button id="inVideo">Scoreboard in video</button><br>
        <button id="scoreReset">Reset score</button>
      </div>
      <div class="team away">
        <input id="awayName" maxlength="16" autocomplete="off">
        <div class="pts" id="awayScore">0</div>
        <div class="btns">
          <button data-team="Away" data-p="5">Try +5</button><button data-team="Away" data-p="2">Conv +2</button>
          <button data-team="Away" data-p="3">Pen +3</button><button data-team="Away" data-p="-1">−1</button>
        </div>
      </div>
    </div>
  </div>
  <div id="right">
    <button id="rec">Record</button>
    <div class="row">
      <button id="follow">Follow</button>
      <button id="autozoom">Auto zoom</button>
    </div>
    <div class="box">
      <div class="label"><span>Zoom</span><span id="zoomText"></span></div>
      <input id="zoom" type="range" min="0" max="1" step="0.005" value="0">
      <div class="row" style="margin-top:8px">
        <button id="zout">−</button>
        <button id="zin">+</button>
      </div>
    </div>
    <div class="box">
      <div class="label"><span>Turn the mount</span><span id="mountState"></span></div>
      <div class="pad">
        <span></span><button data-move="tilt" data-v="-1">▲</button><span></span>
        <button data-move="pan" data-v="-1">◀</button><span class="mid">hold</span><button data-move="pan" data-v="1">▶</button>
        <span></span><button data-move="tilt" data-v="1">▼</button><span></span>
      </div>
    </div>
    <button id="stream">Go live</button>
    <button id="setbtn">⚙︎ Settings</button>
    <div id="conn">Connecting…</div>
  </div>
</div>
<div id="sheet"><div class="panel">
  <div class="top"><h2>Settings</h2><button id="setclose">Done</button></div>
  <div id="seterr"></div>
  <div id="setlist"></div>
</div></div>
<div id="pinbox"><div class="box">
  <div>Enter the PIN shown on the iPhone<br><span style="color:var(--dim);font-size:13px">Settings › iPad remote</span></div>
  <input id="pin" type="tel" inputmode="numeric" pattern="[0-9]*" maxlength="4" autocomplete="off">
  <div id="pinmsg"></div>
  <button id="pinok">Connect</button>
</div></div>
<script>
let pin = '';
try { pin = localStorage.getItem('rugbycam.pin') || ''; } catch (e) {}
let last = null, dragging = false, failures = 0;
const $ = id => document.getElementById(id);

const pinOpen = () => $('pinbox').style.display === 'flex';
function askPin(message) {
  if (pinOpen()) return;              // already asking: never clear what is being typed
  $('pinmsg').textContent = message || '';
  $('pin').value = '';
  $('pinbox').style.display = 'flex';
  $('pin').focus();
}
$('pinok').onclick = () => {
  const typed = $('pin').value.replace(/[^0-9]/g, '');
  if (typed.length !== 4) { $('pinmsg').textContent = 'The PIN has 4 digits.'; return; }
  pin = typed;
  try { localStorage.setItem('rugbycam.pin', pin); } catch (e) {}
  $('pinbox').style.display = 'none';
};
$('pin').addEventListener('keydown', e => { if (e.key === 'Enter') $('pinok').click(); });

async function call(path) {
  const r = await fetch(path + (path.includes('?') ? '&' : '?') + 'pin=' + encodeURIComponent(pin), { cache: 'no-store' });
  if (r.status === 403) { askPin(pin ? 'That PIN is not right. Look again on the iPhone.' : ''); throw new Error('pin'); }
  return r;
}

function chip(text, cls) { const d = document.createElement('span'); d.className = 'chip ' + (cls || ''); d.textContent = text; return d; }

function show(s) {
  last = s;
  $('rec').textContent = s.recording ? 'Stop  ' + s.recordingTime : 'Record';
  $('rec').classList.toggle('stop', s.recording);
  $('follow').classList.toggle('on', s.follow);
  $('autozoom').classList.toggle('on', s.autoZoom);
  $('stream').textContent = s.streamOn ? 'End stream' : 'Go live';
  $('stream').classList.toggle('on', s.streamOn);
  $('stream').disabled = !s.streamAvailable;
  $('zoomText').textContent = s.zoomText;
  if (!dragging) $('zoom').value = s.zoomPosition;
  $('paused').style.display = s.cameraPaused ? 'flex' : 'none';
  const c = $('chips'); c.innerHTML = '';
  if (s.recording) c.appendChild(chip('● REC ' + s.recordingTime, 'red'));
  if (s.streamOn) c.appendChild(chip(s.streamText, 'red'));
  if (s.battery >= 0) c.appendChild(chip('Battery ' + s.battery + '%' + (s.charging ? ' ⚡' : ''), s.battery <= 20 && !s.charging ? 'warn' : ''));
  if (s.hot) c.appendChild(chip('iPhone is hot', 'warn'));
  if (s.freeSpace) c.appendChild(chip(s.freeSpace));
  if (s.camera) c.appendChild(chip(s.camera));
  if (s.mount) c.appendChild(chip(s.mount));
  $('tracking').textContent = s.tracking;
  $('mountState').textContent = s.mountReady ? 'ready' : 'not linked';
  $('homeScore').textContent = s.homeScore;
  $('awayScore').textContent = s.awayScore;
  if (document.activeElement !== $('homeName')) $('homeName').value = s.home;
  if (document.activeElement !== $('awayName')) $('awayName').value = s.away;
  $('gameTime').textContent = s.recording ? s.recordingTime : '00:00';
  $('periodText').textContent = s.period === 2 ? '2nd half' : '1st half';
  $('inVideo').classList.toggle('on', s.scoreInVideo);
  $('inVideo').textContent = s.scoreInVideo ? 'Scoreboard in video: on' : 'Scoreboard in video: off';
  $('notice').textContent = s.notice || '';
  drawBoxes();
}

function drawBoxes() {
  const cv = $('ov'), r = cv.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
  cv.width = r.width * dpr; cv.height = r.height * dpr;
  const g = cv.getContext('2d'); g.scale(dpr, dpr); g.clearRect(0, 0, r.width, r.height);
  if (!last) return;
  // The picture is 16:9 and fills the view.
  const W = r.width, H = r.height;
  g.lineWidth = 2;
  g.strokeStyle = 'rgba(255,255,255,0.6)';
  for (const p of last.players) g.strokeRect(p[0] * W, p[1] * H, p[2] * W, p[3] * H);
  if (last.ball) {
    const b = last.ball;
    g.strokeStyle = last.ballConfirmed ? '#2fb36b' : '#f6b620'; g.lineWidth = 3;
    g.strokeRect(b[0] * W - 4, b[1] * H - 4, b[2] * W + 8, b[3] * H + 8);
  }
}

async function poll() {
  if (!pin || pinOpen()) { setTimeout(poll, 500); return; }
  try {
    const r = await call('/status');
    show(await r.json());
    failures = 0;
    $('conn').textContent = 'Connected to the iPhone';
  } catch (e) {
    if (e.message !== 'pin') { failures++; $('conn').textContent = 'No connection to the iPhone. Is RugbyCam open?'; }
  }
  setTimeout(poll, failures ? 2000 : 500);
}

let imgURL = null;
async function frames() {
  if (pin && !pinOpen() && !document.hidden) {
    try {
      const r = await call('/frame.jpg');
      if (r.status === 200) {
        const blob = await r.blob();
        const url = URL.createObjectURL(blob);
        $('img').src = url;
        if (imgURL) URL.revokeObjectURL(imgURL);
        imgURL = url;
      }
    } catch (e) {}
  }
  setTimeout(frames, 200);
}

async function cmd(name, value) {
  try {
    const r = await call('/cmd?do=' + name + (value !== undefined ? '&v=' + value : ''));
    show(await r.json());
  } catch (e) {}
}


$('rec').onclick = () => {
  if (last && last.recording && !confirm('Stop the recording?')) return;
  cmd('record');
};
$('follow').onclick = () => cmd('follow', last && last.follow ? 0 : 1);
$('autozoom').onclick = () => cmd('autozoom', last && last.autoZoom ? 0 : 1);
$('stream').onclick = () => {
  if (last && last.streamOn && !confirm('End the live stream?')) return;
  cmd('stream');
};
$('zin').onclick = () => cmd('zoomstep', 1.25);
$('zout').onclick = () => cmd('zoomstep', 0.8);
let zoomTimer = null;
$('zoom').addEventListener('input', () => {
  dragging = true;
  clearTimeout(zoomTimer);
  zoomTimer = setTimeout(() => cmd('zoom', $('zoom').value), 60);
});
$('zoom').addEventListener('change', () => { dragging = false; cmd('zoom', $('zoom').value); });
window.addEventListener('resize', drawBoxes);

// ---- Mount arrows: hold to turn, let go to stop ----
let moveTimer = null, moveBtn = null;
function stopMove() {
  if (!moveTimer) return;
  clearInterval(moveTimer); moveTimer = null;
  if (moveBtn) moveBtn.classList.remove('held');
  moveBtn = null;
  cmd('moveStop');
}
document.querySelectorAll('[data-move]').forEach(b => {
  b.addEventListener('pointerdown', e => {
    e.preventDefault();
    stopMove();
    moveBtn = b; b.classList.add('held');
    const send = () => call('/cmd?do=' + b.dataset.move + '&v=' + b.dataset.v).catch(() => {});
    send();
    moveTimer = setInterval(send, 120);
    try { b.setPointerCapture(e.pointerId); } catch (x) {}
  });
  ['pointerup', 'pointercancel', 'lostpointercapture'].forEach(n => b.addEventListener(n, stopMove));
  b.addEventListener('contextmenu', e => e.preventDefault());
});
window.addEventListener('blur', stopMove);
document.addEventListener('visibilitychange', () => { if (document.hidden) stopMove(); });

// ---- Scoreboard ----
document.querySelectorAll('[data-team]').forEach(b => {
  b.onclick = () => cmd('score' + b.dataset.team, b.dataset.p);
});
$('scoreReset').onclick = () => { if (confirm('Set both scores to 0?')) cmd('scoreReset'); };
$('periodBtn').onclick = () => cmd('period', last && last.period === 2 ? 1 : 2);
$('inVideo').onclick = () => cmd('scoreShow', last && last.scoreInVideo ? 0 : 1);
for (const [id, key] of [['homeName', 'homeName'], ['awayName', 'awayName']]) {
  $(id).addEventListener('change', () => call('/set?key=' + key + '&v=' + encodeURIComponent($(id).value)).catch(() => {}));
  $(id).addEventListener('keydown', e => { if (e.key === 'Enter') $(id).blur(); });
}

// ---- Settings ----
const FIELDS = [
  ['Recording', [
    { k:'quality', t:'Video quality', type:'select', opts:[['uhd60','4K 60'],['uhd30','4K 30'],['hd60','1080p 60']], noRec:true },
    { k:'codec', t:'File format', type:'select', opts:[['hevc','HEVC (smaller files)'],['h264','H.264 (most compatible)']] },
    { k:'saveToPhotos', t:'Save recordings to Photos', type:'bool' },
    { k:'stabilisation', t:'Stabilise the picture', type:'bool', noRec:true },
  ]],
  ['Tracking', [
    { k:'showOverlay', t:'Show what the tracking sees', type:'bool' },
    { k:'lensStepsOnly', t:'Only use the real lenses (0.5x, 1x, 2x, tele)', type:'bool' },
    { k:'autoZoomMinDisplay', t:'Widest auto zoom', type:'range', min:0.5, max:4, step:0.5, fmt:v=>v+'x' },
    { k:'autoZoomMaxDisplay', t:'Tightest auto zoom', type:'range', min:1, max:15, step:0.5, fmt:v=>v+'x' },
    { k:'zoomTightness', t:'How tightly to frame the players', type:'range', min:0.35, max:0.8, step:0.01, fmt:v=>Math.round(v*100)+' %' },
    { k:'followSpeed', t:'How eagerly the mount follows', type:'range', min:0.3, max:3, step:0.05, fmt:v=>(+v).toFixed(2) },
    { k:'detectionRate', t:'Looks per second', type:'range', min:4, max:30, step:1, fmt:v=>Math.round(v) },
    { k:'ballConfidence', t:'Weakest ball detection to accept', type:'range', min:0.05, max:0.6, step:0.01, fmt:v=>(+v).toFixed(2) },
    { k:'searchZoom', t:'Ball search zoom', type:'range', min:1, max:4, step:0.1, fmt:v=>(+v).toFixed(1)+'x' },
  ]],
  ['Mount', [
    { type:'mount' },
    { k:'tiltEnabled', t:'Allow tilting up and down', type:'bool' },
    { k:'invertPan', t:'Reverse left and right', type:'bool' },
    { k:'invertTilt', t:'Reverse up and down', type:'bool' },
    { k:'manualSpeed', t:'Arrow button speed', type:'range', min:0.1, max:1, step:0.05, fmt:v=>Math.round(v*100)+' %' },
  ]],
  ['Training', [
    { k:'saveHardFrames', t:'While recording, save moments the ball is lost', type:'bool' },
    { k:'importKeep', t:'Pictures to keep per imported video', type:'range', min:20, max:200, step:10, fmt:v=>Math.round(v) },
    { type:'model' },
  ]],
  ['Live stream', [
    { k:'streamURL', t:'Stream address', type:'text' },
    { k:'streamResolution', t:'Stream size', type:'select', opts:[['p720','720p'],['p1080','1080p'],['p1440','1440p'],['p2160','4K']] },
    { k:'streamFPS', t:'Stream frames per second', type:'select', opts:[['30','30'],['60','60']] },
    { k:'streamBitrateMbps', t:'Stream quality', type:'range', min:2, max:40, step:0.5, fmt:v=>(+v).toFixed(1)+' Mbit/s' },
    { type:'note', t:'The stream key can only be entered on the iPhone. Stream changes apply the next time you go live.' },
  ]],
];
let S = null, editing = null;

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; }

function buildSettings() {
  const list = $('setlist'); list.innerHTML = '';
  for (const [title, items] of FIELDS) {
    list.appendChild(el('div', 'sec', title));
    for (const f of items) {
      const box = el('div', 'item');
      if (f.type === 'note') { box.appendChild(el('div', 'note', f.t)); list.appendChild(box); continue; }
      if (f.type === 'mount') {
        const head = el('div', 'head'); head.appendChild(el('span', '', 'Status')); head.appendChild(el('span', 'val', S._mount));
        box.appendChild(head);
        const b = el('button', '', S._mountIdle ? 'Connect to the XbotGo mount' : 'Disconnect');
        b.style.marginTop = '10px';
        b.onclick = () => cmd(S._mountIdle ? 'mountConnect' : 'mountDisconnect').then(loadSettings);
        box.appendChild(b); list.appendChild(box); continue;
      }
      if (f.type === 'model') {
        box.appendChild(el('div', '', 'Ball model'));
        box.appendChild(el('div', 'note', S._ballModel || ''));
        const b = el('button', '', 'Look for model files again'); b.style.marginTop = '10px';
        b.onclick = () => cmd('reloadModels').then(() => setTimeout(loadSettings, 1500));
        box.appendChild(b); list.appendChild(box); continue;
      }
      const locked = f.noRec && S._recording;
      if (locked) box.classList.add('off');
      const head = el('div', 'head');
      head.appendChild(el('span', '', f.t + (locked ? ' (stop recording first)' : '')));
      const v = S[f.k];
      if (f.type === 'bool') {
        const lab = el('label', 'switch'); const inp = el('input'); inp.type = 'checkbox'; inp.checked = !!v;
        inp.onchange = () => setValue(f.k, inp.checked ? 1 : 0);
        lab.appendChild(inp); lab.appendChild(el('span')); head.appendChild(lab); box.appendChild(head);
      } else if (f.type === 'select') {
        const sel = el('select');
        for (const [val, text] of f.opts) { const o = el('option', '', text); o.value = val; if (String(v) === val) o.selected = true; sel.appendChild(o); }
        sel.onchange = () => setValue(f.k, sel.value);
        head.appendChild(sel); box.appendChild(head);
      } else if (f.type === 'range') {
        const val = el('span', 'val', f.fmt(v)); head.appendChild(val); box.appendChild(head);
        const inp = el('input'); inp.type = 'range'; inp.min = f.min; inp.max = f.max; inp.step = f.step; inp.value = v;
        inp.oninput = () => { editing = f.k; val.textContent = f.fmt(inp.value); };
        inp.onchange = () => { editing = null; setValue(f.k, inp.value); };
        box.appendChild(inp);
      } else if (f.type === 'text') {
        box.appendChild(head);
        const inp = el('input'); inp.type = 'text'; inp.value = v || ''; inp.autocapitalize = 'off'; inp.autocomplete = 'off'; inp.spellcheck = false;
        inp.onfocus = () => { editing = f.k; };
        inp.onchange = () => { editing = null; setValue(f.k, inp.value); };
        inp.onblur = () => { editing = null; };
        box.appendChild(inp);
      }
      list.appendChild(box);
    }
  }
}

function showSettings(r) {
  S = r.settings;
  $('seterr').textContent = r.error || '';
  if (!editing) buildSettings();
}

async function loadSettings() {
  try { showSettings(await (await call('/settings')).json()); } catch (e) {}
}

async function setValue(key, value) {
  try { showSettings(await (await call('/set?key=' + encodeURIComponent(key) + '&v=' + encodeURIComponent(value))).json()); }
  catch (e) { $('seterr').textContent = 'Could not reach the iPhone.'; }
}

let settingsTimer = null;
$('setbtn').onclick = () => {
  $('sheet').style.display = 'flex';
  loadSettings();
  clearInterval(settingsTimer);
  settingsTimer = setInterval(() => { if (!editing) loadSettings(); }, 3000);
};
$('setclose').onclick = () => { $('sheet').style.display = 'none'; clearInterval(settingsTimer); editing = null; };
$('sheet').addEventListener('click', e => { if (e.target === $('sheet')) $('setclose').click(); });

if (!pin) askPin();
poll();
frames();
</script>
</body>
</html>
"""#
}
