// The checks before a submit: fillLogin / fillCode fill the testsite's challenge pages in a headless Chrome,
// then submitForm decides whether to click. Runs the extension's own page functions (read from
// extension/background.js), the way runInForm runs them, without the extension, otto or a window.
//   node tests/submit_checks.mjs        (CHROME=<path> to pick the browser; scratch files go in $TMPDIR)
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';

const here = path.dirname(new URL(import.meta.url).pathname);
const PORT = 8791;
const DEBUG = 9341;
const site = `http://127.0.0.1:${PORT}`;
const chromeBin = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// the extension's functions, from the real file (a stub `chrome` lets its top level run)
const stub = new Proxy(function () {}, { get: (_, k) => (k === 'then' ? undefined : stub), apply: () => stub });
const ctx = vm.createContext({ chrome: stub, console });
vm.runInContext(fs.readFileSync(path.join(here, '../extension/background.js'), 'utf8'), ctx);
const { fillLogin, fillCode, submitForm } = ctx;
const WAIT = vm.runInContext('SUBMIT_WAIT_MS', ctx);

const user = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-submit-'));
const server = spawn('python3', ['-I', path.join(here, '../testsite/server.py'), String(PORT)], { stdio: 'ignore' });
const chrome = spawn(chromeBin, [
  '--headless=new', `--remote-debugging-port=${DEBUG}`, `--user-data-dir=${user}`, '--no-first-run', '--no-default-browser-check',
  // nothing leaves the machine: the fake widgets' google / cloudflare / hcaptcha frames just fail to load
  '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
  '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows',
  'about:blank',
], { stdio: 'ignore' });
// if the run dies: at least stop the browser and the site
process.on('exit', () => {
  chrome.kill();
  server.kill();
});

const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
async function until(f, ms = 15000) {
  const end = Date.now() + ms;
  for (;;) {
    try {
      const v = await f();
      if (v) return v;
    } catch {}
    if (Date.now() > end) throw new Error('timed out');
    await sleep(150);
  }
}

class Page {
  static async open(url) {
    const t = await (await fetch(`http://127.0.0.1:${DEBUG}/json/new?${url}`, { method: 'PUT' })).json();
    const p = new Page();
    p.ws = new WebSocket(t.webSocketDebuggerUrl);
    p.id = t.id;
    p.n = 0;
    p.waiting = new Map();
    p.ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      p.waiting.get(m.id)?.(m);
      p.waiting.delete(m.id);
    };
    await new Promise((ok, no) => { p.ws.onopen = ok; p.ws.onerror = no; });
    await until(async () => (await p.eval('document.readyState')) === 'complete');
    return p;
  }
  async eval(js) {
    const id = ++this.n;
    const m = await new Promise((ok) => {
      this.waiting.set(id, ok);
      this.ws.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression: js, returnByValue: true, awaitPromise: true } }));
    });
    if (m.error || m.result.exceptionDetails) throw new Error(JSON.stringify(m.error || m.result.exceptionDetails));
    return m.result.result.value;
  }
  // what runInForm does: fill (it finds the button), then submitForm
  async fill(func, args, submit) {
    const r = await this.eval(`(${func})(${args.map((a) => JSON.stringify(a)).join(', ')}, ${submit}, false, false)`);
    if (r.error || !submit) return r;
    const t0 = Date.now();
    const s = await this.eval(`(${submitForm})(${WAIT})`);
    return { ...r, ...s, took: Date.now() - t0 };
  }
  close() {
    this.ws.close();
    return fetch(`http://127.0.0.1:${DEBUG}/json/close/${this.id}`);
  }
}

const SITES = ['127.0.0.1'];
const LOGIN = { username: 'demo', password: 'PREVIEW-not-a-password' };
// [page, filler, submitted, held (or null), took at least ms, took at most ms]
const cases = [
  ['plain', 'login', true, null, 0, 1000],
  ['turnstile-solves', 'login', true, null, 1900, 4000],
  ['turnstile-stuck', 'login', false, "a Cloudflare check on the page isn't done", WAIT - 100, WAIT + 1500],
  ['turnstile-hidden', 'login', true, null, WAIT - 100, WAIT + 1500],
  ['turnstile-hidden-off', 'login', false, "a Cloudflare check on the page isn't done", WAIT - 100, WAIT + 1500],
  ['recaptcha-v2', 'login', false, "a reCAPTCHA on the page isn't done", 0, 1000],
  ['recaptcha-v2-solved', 'login', true, null, 0, 1000],
  ['recaptcha-v3', 'login', true, null, 0, 1000],
  ['hcaptcha', 'login', false, "an hCaptcha on the page isn't done", 0, 1000],
  ['hcaptcha-invisible', 'login', true, null, 0, 1000],
  ['friendly', 'login', true, null, 1100, 3000],
  ['other-form-captcha', 'login', true, null, 0, 1000],
  ['terms', 'login', false, 'the form needs the terms box ticked', 0, 1000],
  ['kvkk', 'login', false, 'the form needs the terms box ticked', 0, 1000],
  ['remember', 'login', true, null, 0, 1000],
  ['robot', 'login', false, 'the form needs the "I\'m not a robot" box ticked', 0, 1000],
  ['invalid', 'login', false, 'the form says "Email" isn\'t right', 0, 1000],
  ['typed-captcha', 'login', false, 'the page wants a captcha typed in', 0, 1000],
  ['disabled-wakes', 'login', true, null, 1400, 3500],
  ['code', 'code', true, null, 0, 1000],
  ['code-turnstile', 'code', false, "a Cloudflare check on the page isn't done", WAIT - 100, WAIT + 1500],
];

let pass = 0;
let fail = 0;
const check = (name, ok, why = '') => {
  if (ok) pass++;
  else fail++;
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : `  ${why}`}`);
};

try {
  await until(() => fetch(`http://127.0.0.1:${DEBUG}/json/version`).then((r) => r.ok));
  await until(() => fetch(`${site}/challenge/plain`).then((r) => r.ok));

  console.log('nothing is submitted unless asked');
  {
    const p = await Page.open(`${site}/challenge/plain`);
    const r = await p.fill(fillLogin, [SITES, LOGIN], false);
    check('fill without submit leaves the form alone', r.submitted === false && !('held' in r) && (await p.eval('window.sent || 0')) === 0, JSON.stringify(r));
    const s = await p.eval(`(${submitForm})(${WAIT})`);
    check('submitForm with nothing left by a fill does nothing', s.submitted === false && (await p.eval('window.sent || 0')) === 0, JSON.stringify(s));
    const probe = await p.eval(`(${fillLogin})(${JSON.stringify(SITES)}, ${JSON.stringify(LOGIN)}, true, false, true)`);
    check('the probe (dry run) still scores the form', probe.score === 3, JSON.stringify(probe));
    await p.close();
  }

  console.log('real submits that leave the page');
  for (const [where, what] of [['/', 'the plain sign-in form'], ['/shadow', 'a form in a shadow root, button outside any form']]) {
    const p = await Page.open(`${site}${where}`);
    const r = await p.fill(fillLogin, [SITES, LOGIN], true);
    // a wrong password: the site answers with /?err=1, either way the form went to /login
    const left = await until(async () => (await p.eval('location.pathname + location.search')) === '/?err=1' && 'ok', 5000).catch(() => null);
    check(`${what}: submitted and the site answered`, r.submitted === true && !('held' in r) && !!left, JSON.stringify(r));
    await p.close();
  }

  console.log(`each page, filled and submitted (waits up to ${WAIT}ms; run side by side)`);
  const results = await Promise.all(
    cases.map(async ([name, kind, submitted, held, min, max]) => {
      const p = await Page.open(`${site}/challenge/${name}`);
      const r = kind === 'login' ? await p.fill(fillLogin, [SITES, LOGIN], true) : await p.fill(fillCode, [SITES, '123456'], true);
      const sent = await p.eval('window.sent || 0');
      await p.close();
      return { name, submitted, held, min, max, r, sent };
    }),
  );
  for (const { name, submitted, held, min, max, r, sent } of results) {
    const ok =
      !r.error && r.submitted === submitted && (held ? r.held === held : !('held' in r)) && sent === (submitted ? 1 : 0) && r.took >= min && r.took <= max;
    const what = submitted ? `submitted${r.took > 900 ? ` after ${(r.took / 1000).toFixed(1)}s` : ''}` : `held: ${r.held}`;
    check(`${name}: ${what}`, ok, `got ${JSON.stringify(r)}, page saw ${sent} submit(s)`);
  }
} finally {
  console.log(`${pass} passed, ${fail} failed`);
  server.kill();
  const gone = new Promise((ok) => chrome.once('exit', ok));
  chrome.kill();
  await Promise.race([gone, sleep(5000)]);
  fs.rmSync(user, { recursive: true, force: true });
}
process.exit(fail ? 1 : 0);
