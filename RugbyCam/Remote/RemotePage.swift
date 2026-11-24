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
    <button id="stream">Go live</button>
    <div id="conn">Connecting…</div>
  </div>
</div>
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

if (!pin) askPin();
poll();
frames();
</script>
</body>
</html>
"""#
}
