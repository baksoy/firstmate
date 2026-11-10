#!/usr/bin/env node
// fm-glimpse-ask.mjs - node half of bin/fm-glimpse-ask.sh (see its header for the contract).
// Opens one small glimpseui window with a prompt and one button per option,
// waits for a click, prints the answer, and exits with a distinct code per outcome.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const EXIT = { answered: 0, usage: 2, disabled: 10, dismissed: 11, timeout: 12, unavailable: 13 };
const CORNERS = ['bottom-right', 'bottom-left', 'top-right', 'top-left', 'center'];

function usage(msg) {
  if (msg) process.stderr.write(`error: ${msg}\n`);
  process.stderr.write('usage: fm-glimpse-ask.sh [--title T] [--timeout SEC] [--position CORNER] [--x N --y N]\n'
    + '                        [--primary N] [--json] [--demo] [--] <prompt> <option> [<option>...]\n');
  process.exit(EXIT.usage);
}

function parse(argv) {
  const o = { title: 'Firstmate', timeout: 120, position: 'bottom-right', primary: 1, json: false, rest: [] };
  const num = (flag, v) => {
    if (v === undefined || !/^-?\d+$/.test(v)) usage(`${flag} needs an integer`);
    return Number(v);
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--') { o.rest.push(...argv.slice(i + 1)); break; }
    else if (a === '--title') o.title = argv[++i] ?? usage('--title needs a value');
    else if (a === '--timeout') o.timeout = num(a, argv[++i]);
    else if (a === '--position') o.position = argv[++i] ?? usage('--position needs a value');
    else if (a === '--x') o.x = num(a, argv[++i]);
    else if (a === '--y') o.y = num(a, argv[++i]);
    else if (a === '--primary') o.primary = num(a, argv[++i]);
    else if (a === '--json') o.json = true;
    else if (a === '--demo') o.demo = true;
    else if (a.startsWith('--')) usage(`unknown flag ${a}`);
    else o.rest.push(a);
  }
  if (o.demo && o.rest.length === 0) o.rest = ['Merge PR?', 'Yes', 'No', 'Not now'];
  if (!CORNERS.includes(o.position)) usage(`--position must be one of ${CORNERS.join(', ')}`);
  if (o.rest.length < 3) usage('need a prompt and at least two options');
  if (o.rest.length > 7) usage('at most six options');
  [o.prompt, ...o.options] = o.rest;
  if (o.options.some((s) => s === '')) usage('options must be non-empty');
  if (o.primary < 1 || o.primary > o.options.length) usage('--primary out of range');
  return o;
}

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Blueprint-paper tokens inlined from the captain's Lavish house style; no external links.
function render(o) {
  const buttons = o.options.map((opt, i) =>
    `<button class="${i + 1 === o.primary ? 'pri' : ''}" onclick="glimpse.send({i:${i}})"><kbd>${i + 1}</kbd>${esc(opt)}</button>`).join('');
  return `<!doctype html><html><head><meta charset="utf-8"><style>
:root{--paper:#fff;--paper-2:#EAF5FE;--ink:#001E5B;--ink-3:#4B5B7C;--rule:#CFE3F8;--accent:#066AFE;--accent-deep:#022AC0}
*{box-sizing:border-box;margin:0;padding:0;min-width:0}
html,body{height:100%;overflow:hidden}
body{font:14px/1.45 system-ui,-apple-system,'Inter',sans-serif;color:var(--ink);-webkit-font-smoothing:antialiased;
background:radial-gradient(400px 160px at 100% -20%,var(--paper-2),rgba(234,245,254,0) 70%),var(--paper);
border:1px solid var(--rule);border-left:4px solid var(--accent);padding:14px 16px;display:flex;flex-direction:column;gap:10px}
.eyebrow{font:500 10px ui-monospace,'JetBrains Mono',monospace;letter-spacing:.18em;text-transform:uppercase;color:var(--accent)}
.q{font-weight:600;font-size:16px;line-height:1.3;padding-bottom:.06em;flex:1;overflow:hidden}
.row{display:flex;gap:8px;flex-wrap:wrap}
button{font:500 13px system-ui,-apple-system,sans-serif;color:var(--accent-deep);background:var(--paper);border:1px solid var(--rule);
border-radius:9px;padding:7px 12px;cursor:pointer}
button:hover{border-color:var(--accent);background:var(--paper-2)}
button.pri{background:var(--accent);border-color:var(--accent);color:#fff}
kbd{font:500 10px ui-monospace,monospace;opacity:.55;margin-right:6px}
.hint{font:400 10px ui-monospace,monospace;color:var(--ink-3)}
</style></head><body>
<div class="eyebrow">Firstmate &middot; needs you</div>
<div class="q">${esc(o.prompt)}</div>
<div class="row">${buttons}</div>
<div class="hint">press 1-${o.options.length} &middot; esc = not now</div>
<script>
document.addEventListener('keydown',function(e){
 if(e.key==='Escape'){glimpse.close();return}
 var n=parseInt(e.key,10);if(n>=1&&n<=${o.options.length})glimpse.send({i:n-1});
});
</script></body></html>`;
}

async function loadGlimpse() {
  const dir = process.env.FM_GLIMPSE_MODULE;
  try {
    if (dir) return await import(pathToFileURL(createRequire(dir + '/').resolve(dir)).href);
    return await import('glimpseui');
  } catch (e) {
    process.stderr.write(`error: glimpseui is not loadable (${e.message}); see the install notes in bin/fm-glimpse-ask.sh\n`);
    process.exit(EXIT.unavailable);
  }
}

// Window origin is bottom-left based. A hidden probe window reports the main screen's visible
// frame so corners can be computed; any probe failure falls back to a bottom-left-ish offset.
async function place(g, o, w, h) {
  if (o.x != null && o.y != null) return { x: o.x, y: o.y };
  if (o.position === 'center') return {};
  const info = await new Promise((resolve) => {
    const t = setTimeout(() => { try { p.close(); } catch { /* ignore */ } resolve(null); }, 4000);
    const p = g.open('<html></html>', { hidden: true, width: 10, height: 10 });
    p.on('ready', (i) => { clearTimeout(t); p.close(); resolve(i); });
    p.on('error', () => { clearTimeout(t); resolve(null); });
  });
  const s = info?.screen;
  const m = 24;
  if (!s || s.visibleWidth == null) return { x: 80, y: 80 };
  const right = o.position.endsWith('right');
  const top = o.position.startsWith('top');
  return {
    x: s.visibleX + (right ? s.visibleWidth - w - m : m),
    y: s.visibleY + (top ? s.visibleHeight - h - m : m),
  };
}

function finish(o, outcome, answer) {
  if (o.json) process.stdout.write(JSON.stringify(answer == null ? { outcome } : { outcome, answer }) + '\n');
  else if (outcome === 'answered') process.stdout.write(answer + '\n');
  process.exit(EXIT[outcome]);
}

const o = parse(process.argv.slice(2));
const g = await loadGlimpse();
const width = 380;
const height = 150 + 22 * Math.floor((o.prompt.length + 7 * o.options.length) / 60);
const pos = await place(g, o, width, height);
const win = g.open(render(o), { width, height, title: o.title, frameless: true, floating: true, noDock: true, autoClose: true, ...pos });

let settled = false;
const settle = (outcome, answer) => {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  try { win.close(); } catch { /* already gone */ }
  finish(o, outcome, answer);
};
const timer = o.timeout > 0 ? setTimeout(() => settle('timeout'), o.timeout * 1000) : null;

win.on('message', (d) => {
  const i = d?.i;
  if (Number.isInteger(i) && i >= 0 && i < o.options.length) settle('answered', o.options[i]);
});
win.on('closed', () => settle('dismissed'));
win.on('error', (e) => {
  process.stderr.write(`error: ${e.message}\n`);
  settled = true;
  process.exit(EXIT.unavailable);
});
