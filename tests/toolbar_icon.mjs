// The toolbar icon, in a headless Chrome with the real unpacked extension: the worker starts cleanly, the
// offscreen page reports light or dark mode and the icon follows it, and a fill turns that tab's icon into
// the app's tile until a moment after it's done. The extension is loaded over the DevTools pipe
// (Extensions.loadUnpacked), since branded Chrome ignores --load-extension. The scratch profile has no
// native messaging host, so the extension never reaches otto.
//   node tests/toolbar_icon.mjs        (CHROME=<path> to pick the browser; scratch files go in $TMPDIR)
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const PORT = 8792;
const site = `http://127.0.0.1:${PORT}`;
const chromeBin = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const user = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-icon-'));
const server = spawn('python3', ['-I', path.join(here, '../testsite/server.py'), String(PORT)], { stdio: 'ignore' });
const chrome = spawn(chromeBin, [
  '--headless=new', '--remote-debugging-pipe', '--enable-unsafe-extension-debugging', `--user-data-dir=${user}`,
  '--no-first-run', '--no-default-browser-check', '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', 'about:blank',
], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
process.on('exit', () => {
  chrome.kill();
  server.kill();
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

// every setIcon call from here on, and whether Chrome took it
await run(`(() => {
  globalThis.calls = [];
  const set = chrome.action.setIcon.bind(chrome.action);
  chrome.action.setIcon = (d) => {
    const c = { tab: d.tabId ?? null, icon: Object.values(d.path || {})[0] || '', t: Date.now() };
    calls.push(c);
    return set(d).then(() => { c.ok = true; }, (e) => { c.err = e.message; throw e; });
  };
})()`);
const calls = () => run('calls');
const iconName = (c) => c.icon.replace(/^icons\/toolbar-|-16\.png$/g, '');

const doc = await until(() => run(`chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] }).then((c) => c.length)`));
check('the offscreen page is open', doc === 1, `${doc}`);
check('it reported the mode at start', typeof (await run('dark')) === 'boolean', `dark: ${await run('dark')}`);
const helper = events.filter((e) => e.method === 'Runtime.consoleAPICalled').map((e) => e.params.args.map((a) => a.value).join(' '));
check('no native host in the scratch profile', helper.some((l) => /helper disconnected.*not found/i.test(l)), helper.join(' | ') || 'no log yet');

// dark mode, by emulating it in the offscreen page
const off = await target(null, 'offscreen.html');
const { sessionId: page } = await send('Target.attachToTarget', { targetId: off.targetId, flatten: true });
const { targetId: tabTarget } = await send('Target.createTarget', { url: `${site}/challenge/plain` });
const tabId = await until(() => run(`chrome.tabs.query({ url: '${site}/challenge/plain' }).then((t) => t[0]?.status === 'complete' && t[0].id)`));
// start from light, whatever this Mac is set to
await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] }, page);
await until(async () => !(await run('dark')));
await sleep(200);
await run('calls.length = 0');
await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }] }, page);
await until(() => run('dark'));
let c = await calls();
check('dark mode reaches the worker', (await run('dark')) === true);
check('the default icon turns dark', c.some((x) => x.tab === null && iconName(x) === 'dark' && x.ok), JSON.stringify(c));
check('open tabs get the dark icon too', c.some((x) => x.tab === tabId && iconName(x) === 'dark' && x.ok));

// a fill: the tab shows the tile, then its resting icon again
await run('calls.length = 0');
const res = await run(`handle('fill', { sites: ['127.0.0.1'], values: { username: 'u', password: 'p' }, submit: false })`);
check('the fill worked', JSON.stringify(res.filled) === '["username","password"]', JSON.stringify(res));
c = await calls();
check('its tab shows the tile while filling', c.length >= 1 && c[0].tab === tabId && iconName(c[0]) === 'active' && c[0].ok, JSON.stringify(c));
check('only that tab', c.every((x) => x.tab === tabId));
await sleep(1500);
check('still the tile a moment after', (await calls()).length === 1);
await sleep(1000);
c = await calls();
check('back to resting (dark) about 2 s after', c.length === 2 && iconName(c[1]) === 'dark' && c[1].ok && c[1].t - c[0].t >= 2000, JSON.stringify(c));

// two fills at once in one tab: one tile, one return
await run('calls.length = 0');
await run(`Promise.all([1, 2].map(() => handle('fill', { sites: ['127.0.0.1'], values: { username: 'u' }, submit: false })))`);
await sleep(2400);
c = await calls();
check('overlapping fills show the tile once and return once', c.map(iconName).join(',') === 'active,dark', c.map(iconName).join(','));

// a fill that submits and loads a new page (the testsite's own login does) keeps the tile through the load
await run(`chrome.tabs.update(${tabId}, { url: '${site}/' })`);
await until(() => run(`chrome.tabs.get(${tabId}).then((t) => t.status === 'complete' && t.url === '${site}/')`));
await run('calls.length = 0');
await run(`handle('fill', { sites: ['127.0.0.1'], values: { username: 'u', password: 'p' }, submit: true })`);
await until(() => run(`chrome.tabs.get(${tabId}).then((t) => t.status === 'complete' && t.url !== '${site}/')`)).catch(() => {});
await sleep(2600);
c = await calls();
check('a submit that loads a page puts the tile back and then returns', c.filter((x) => iconName(x) === 'active').length >= 2 && iconName(c.at(-1)) === 'dark', c.map(iconName).join(','));

// light again
await run('calls.length = 0');
await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] }, page);
await until(async () => !(await run('dark')));
await sleep(200);
c = await calls();
check('light mode brings the light icon back', c.some((x) => x.tab === null && iconName(x) === 'light' && x.ok) && c.some((x) => x.tab === tabId && iconName(x) === 'light'), c.map((x) => `${x.tab}:${iconName(x)}`).join(','));

// a worker that restarts finds the page and asks it, rather than opening a second one
await run('calls.length = 0');
await run('watchScheme()');
await sleep(300);
c = await calls();
const docs = await run(`chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] }).then((c) => c.length)`);
check('a restarted worker asks the open page', docs === 1 && c.some((x) => x.tab === null && iconName(x) === 'light' && x.ok), `${docs} ${JSON.stringify(c)}`);

// the tab closing mid-linger doesn't throw
await run(`handle('fill', { sites: ['127.0.0.1'], values: { username: 'u' }, submit: false }).catch(() => {})`).catch(() => {});
await send('Target.closeTarget', { targetId: tabTarget });
await sleep(2500);
check('a closed tab is forgotten', (await run(`busy.size`)) === 0);

const thrown = events.filter((e) => e.method === 'Runtime.exceptionThrown' && e.sessionId === worker);
check('no uncaught errors in the worker', thrown.length === 0, thrown.map((e) => e.params.exceptionDetails.exception?.description).join(' | '));

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
