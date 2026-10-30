// The toolbar popup, in a headless Chrome with the real unpacked extension: it shows each state the worker
// can be in, the badge and title follow, "Open otto" asks the helper to open the app, and an open popup
// redraws when the state changes. Same setup as toolbar_icon.mjs (no native host, so it starts at no_helper).
//   node tests/toolbar_popup.mjs       (CHROME=<path> to pick the browser; SHOTS=<dir> saves a screenshot
//                                       of each state in light and dark)
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const chromeBin = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const user = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-popup-'));
const chrome = spawn(chromeBin, [
  '--headless=new', '--remote-debugging-pipe', '--enable-unsafe-extension-debugging', `--user-data-dir=${user}`,
  '--no-first-run', '--no-default-browser-check', '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', 'about:blank',
], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
process.on('exit', () => {
  chrome.kill();
  // Chrome may still be writing its profile as it quits
  try {
    fs.rmSync(user, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
  } catch {}
});

// DevTools protocol over the pipe: JSON messages ended by a NUL byte
let n = 0;
const waiting = new Map();
const events = [];
let buf = '';
chrome.stdio[4].on('data', (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf('\0')) >= 0) {
    const m = JSON.parse(buf.slice(0, i));
    buf = buf.slice(i + 1);
    if (m.id && waiting.has(m.id)) {
      const { ok, no } = waiting.get(m.id);
      waiting.delete(m.id);
      m.error ? no(new Error(`${m.error.message} ${m.error.data || ''}`)) : ok(m.result);
    } else if (m.method) events.push(m);
  }
});
const send = (method, params = {}, sessionId) =>
  new Promise((ok, no) => {
    const id = ++n;
    waiting.set(id, { ok, no });
    chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
  });
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
async function until(f, ms = 10000) {
  const end = Date.now() + ms;
  for (;;) {
    try {
      const v = await f();
      if (v) return v;
    } catch {}
    if (Date.now() > end) throw new Error('timed out');
    await sleep(100);
  }
}

let passed = 0;
let failed = 0;
function check(name, ok, detail = '') {
  ok ? passed++ : failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? `: ${detail}` : ''}`);
}

const { id } = await send('Extensions.loadUnpacked', { path: path.join(here, '../extension') });
// (an offscreen page is listed with a type that has changed between Chrome versions, so it's matched by url only)
const target = (type, file) => until(async () => (await send('Target.getTargets')).targetInfos.find((t) => (!type || t.type === type) && t.url === `chrome-extension://${id}/${file}`));
const sw = await target('service_worker', 'background.js');
const { sessionId: worker } = await send('Target.attachToTarget', { targetId: sw.targetId, flatten: true });
await send('Runtime.enable', {}, worker);
const run = async (expression) => {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, worker);
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  return r.result.value;
};


const shots = process.env.SHOTS;
const { targetId: popTarget } = await send('Target.createTarget', { url: `chrome-extension://${id}/popup.html` });
const { sessionId: pop } = await send('Target.attachToTarget', { targetId: popTarget, flatten: true });
await send('Runtime.enable', {}, pop);
await send('Emulation.setDeviceMetricsOverride', { width: 288, height: 400, deviceScaleFactor: 2, mobile: false }, pop);
const inPopup = async (expression) => {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, pop);
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  return r.result.value;
};
const shown = () => inPopup(`(() => {
  const vis = (id) => !document.getElementById(id).hidden;
  const b = document.getElementById('open');
  return { tone: document.getElementById('state').className.replace('state', '').trim(), title: document.getElementById('title').textContent,
    text: vis('text') ? document.getElementById('text').textContent : null, note: vis('note') ? document.getElementById('note').textContent : null,
    button: vis('open') ? b.textContent + (b.disabled ? ' (disabled)' : '') + (b.className ? ' ' + b.className : '') : null };
})()`);
async function shoot(name) {
  if (!shots) return;
  for (const scheme of ['light', 'dark']) {
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] }, pop);
    await sleep(400); // the button fades to the new colors
    const h = await inPopup('document.body.getBoundingClientRect().height');
    const { data } = await send('Page.captureScreenshot', { clip: { x: 0, y: 0, width: 288, height: h, scale: 1 } }, pop);
    fs.writeFileSync(path.join(shots, `${name}-${scheme}.png`), Buffer.from(data, 'base64'));
  }
}

// the scratch profile has no helper, so this is where it lands by itself
let s = await until(async () => ((await shown()).title === "Chrome can't reach otto" ? shown() : null));
check('no helper: says Chrome can\'t reach otto', s.tone === 'bad' && /sets up the helper/.test(s.text), JSON.stringify(s));
check('no helper: shows Chrome\'s reason', /not found/i.test(s.note || ''), s.note);
check('no helper: no button (nothing could open the app)', s.button === null);
check('no helper: badge and title', (await run('chrome.action.getBadgeText({})')) === '!' && /helper/.test(await run('chrome.action.getTitle({})')));
await shoot('no_helper');

// from here on a helper that's there but quiet, so the worker's reconnect timer can't put no_helper back
await run(`(() => {
  globalThis.posted = [];
  chrome.runtime.connectNative = () => ({ onMessage: { addListener() {} }, onDisconnect: { addListener() {} }, postMessage: (m) => posted.push(m) });
  connect();
})()`);

// the rest by handing the worker what the helper would say; an open popup follows each one
const states = [
  ['not_running', { connected: false }, (s) => s.tone === 'bad' && s.title === "the otto app isn't running" && s.button === 'Open otto'],
  ['locked', { connected: false, error: { code: 'locked', message: 'the vault is locked. open the otto app to unlock it' } }, (s) => s.tone === 'warn' && s.title === 'locked' && s.button === 'Open otto'],
  // one of the service's real refusals (peer.rs), for a browser built without a Developer ID
  ['refused', { connected: false, error: { code: 'denied', message: 'Chromium isn\'t from a verified developer, so otto won\'t trust it with logins' } }, (s) => s.tone === 'bad' && /^Chromium isn't from a verified developer/.test(s.text) && s.button === 'Open otto soft'],
  ['connected', { connected: true, browser: 'Google Chrome' }, (s) => s.tone === 'good' && s.title === 'connected' && /in Google Chrome\./.test(s.text) && s.button === 'Open otto soft'],
];
for (const [name, data, ok] of states) {
  await run(`setStatus(serviceStatus(${JSON.stringify(data)}))`);
  s = await until(async () => {
    const v = await shown();
    return ok(v) ? v : null;
  }, 3000).catch(shown);
  check(`${name}: ${s.title}`, ok(s), JSON.stringify(s));
  const badge = await run('chrome.action.getBadgeText({})');
  check(`${name}: badge ${name === 'connected' ? 'cleared' : '!'}`, badge === (name === 'connected' ? '' : '!'), JSON.stringify(badge));
  await shoot(name);
}

// "Open otto" while it isn't running: the helper gets asked, and the button waits
await run(`setStatus({ state: 'not_running' })`);
await until(async () => (await shown()).button === 'Open otto');
await inPopup(`document.getElementById('open').click()`);
check('the helper is asked to open the app', JSON.stringify(await until(() => run('posted.length && posted'))) === '[{"type":"open_app"}]');
s = await shown();
check('the button waits while it opens', s.button === 'opening… (disabled)', JSON.stringify(s));
await shoot('opening');
await run(`setStatus(serviceStatus({ connected: true, browser: 'Google Chrome' }))`);
s = await until(async () => ((await shown()).title === 'connected' ? shown() : null));
check('connecting ends the wait', s.button === 'Open otto soft', JSON.stringify(s));

// a fresh popup asks the worker where things are
await send('Target.closeTarget', { targetId: popTarget });
const { targetId: again } = await send('Target.createTarget', { url: `chrome-extension://${id}/popup.html` });
const { sessionId: pop2 } = await send('Target.attachToTarget', { targetId: again, flatten: true });
const title2 = await until(async () => {
  const r = await send('Runtime.evaluate', { expression: `document.getElementById('title').textContent`, returnByValue: true }, pop2);
  return r.result.value === 'connected' && r.result.value;
});
check('a newly opened popup starts from the worker\'s state', title2 === 'connected');

const thrown = events.filter((e) => e.method === 'Runtime.exceptionThrown');
check('no uncaught errors', thrown.length === 0, thrown.map((e) => e.params.exceptionDetails.exception?.description).join(' | '));

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
