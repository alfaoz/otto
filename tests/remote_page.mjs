// The remote phone page against tests/remote_page_mock.py, in a headless Chrome at iPhone size: every
// state renders without a script error or a CSP violation, and what the page sends is exactly the API
// otto's remote server takes. With SHOTS=<dir> it also saves each state in light and dark there.
//   node tests/remote_page.mjs      (CHROME=<path> to pick the browser; SHOTS=<dir> for screenshots)
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const PORT = 8796;
const site = `http://127.0.0.1:${PORT}`;
const shots = process.env.SHOTS || null;
const chromeBin = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const user = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-remote-'));
const server = spawn('python3', ['-I', path.join(here, 'remote_page_mock.py'), String(PORT)], { stdio: 'ignore' });
const chrome = spawn(chromeBin, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${user}`, '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', 'about:blank'], {
  stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'],
});
process.on('exit', () => {
  chrome.kill();
  server.kill();
  try {
    fs.rmSync(user, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
  } catch {}
});

let n = 0;
const waiting = new Map();
const listeners = [];
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
    } else if (m.method) for (const l of listeners) l(m);
  }
});
const raw = (method, params = {}, sessionId) =>
  new Promise((ok, no) => {
    const id = ++n;
    waiting.set(id, { ok, no });
    chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
  });
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
async function until(f, ms = 8000) {
  const end = Date.now() + ms;
  for (;;) {
    try {
      const v = await f();
      if (v) return v;
    } catch {}
    if (Date.now() > end) throw new Error('timed out');
    await sleep(80);
  }
}

let passed = 0;
let failed = 0;
function check(name, ok, detail = '') {
  ok ? passed++ : failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail && !ok ? `: ${detail}` : ''}`);
}

await until(() => fetch(`${site}/app.js`).then((r) => r.ok));
const { targetId } = await raw('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await raw('Target.attachToTarget', { targetId, flatten: true });
const send = (m, p) => raw(m, p, sessionId);
await send('Page.enable');
await send('Runtime.enable');
await send('Network.enable');
await send('Log.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
await send('Emulation.setUserAgentOverride', {
  userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1',
});
await send('Page.addScriptToEvaluateOnNewDocument', {
  source: `window.__csp = []; document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(e.violatedDirective + ' ' + e.blockedURI));`,
});

const problems = [];
let offline = false;
listeners.push((m) => {
  if (m.sessionId !== sessionId) return;
  if (m.method === 'Runtime.exceptionThrown') problems.push('exception: ' + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
  if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error' && !/status of 4\d\d|Failed to load resource/.test(m.params.entry.text)) problems.push('log: ' + m.params.entry.text);
  if (m.method === 'Fetch.requestPaused') {
    if (offline && m.params.request.url.includes('/api/')) send('Fetch.failRequest', { requestId: m.params.requestId, errorReason: 'InternetDisconnected' });
    else send('Fetch.continueRequest', { requestId: m.params.requestId });
  }
});

const run = async (expression) => {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  return r.result.value;
};
const mock = (p, body) => fetch(site + p, { method: body === undefined ? 'GET' : 'POST', headers: { 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) }).then((r) => r.json());

async function pairCookie() {
  const r = await fetch(`${site}/api/pair`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ pin: '123456' }) });
  const value = /otto_device=([^;]+)/.exec(r.headers.get('set-cookie'))[1];
  await send('Network.setCookie', { name: 'otto_device', value, url: site, httpOnly: true, sameSite: 'Strict' });
}

let scheme = 'light';
async function open(p, { paired = false, reset = true } = {}) {
  if (reset) await mock('/mock/reset', {});
  await send('Network.clearBrowserCookies');
  if (paired) await pairCookie();
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] });
  await send('Page.navigate', { url: site + p });
  await until(() => run(`document.readyState === 'complete' && !document.querySelector('#app .loading')`));
  await sleep(380);
}
const text = () => run('document.querySelector("#app").innerText');
const view = () => run('document.querySelector("#app").className');
const type = (sel, value) =>
  run(`(() => { const el = document.querySelector(${JSON.stringify(sel)}); el.focus(); el.value = ${JSON.stringify(value)}; el.dispatchEvent(new Event('input', { bubbles: true })); return true; })()`);
const click = (label) =>
  run(`(() => { const b = [...document.querySelectorAll('button')].find((b) => b.innerText.trim() === ${JSON.stringify(label)}); b.click(); return !b.disabled; })()`);
const settle = () => sleep(450);

async function shot(name) {
  const csp = await run('window.__csp');
  if (csp.length) problems.push(`${name}: csp ${csp.join(', ')}`);
  // a stray value rendered as text (a `cond && node` that came out false)
  const stray = /\b(false|true|null|undefined|NaN)\b|\[object/.exec(await text());
  if (stray) problems.push(`${name}: stray "${stray[0]}" on the page`);
  if (!shots) return;
  const { cssContentSize } = await send('Page.getLayoutMetrics');
  const height = Math.max(844, Math.ceil(cssContentSize.height));
  const { data } = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width: 390, height, scale: 1 } });
  fs.writeFileSync(path.join(shots, `${name}-${scheme}.png`), Buffer.from(data, 'base64'));
}

if (shots) fs.mkdirSync(shots, { recursive: true });

// ---- every state, in both modes -----------------------------------------------

for (scheme of shots ? ['light', 'dark'] : ['light']) {
  await open('/');
  await shot('01-home');
  check(`${scheme}: home says nothing's waiting`, /nothing waiting/.test(await text()));

  await open('/r/save-new');
  await shot('02-pair');
  check(`${scheme}: unpaired save asks to pair`, (await view()).includes('view-pair') && /pair this phone/.test(await text()));
  await type('.pin-input', '000000');
  await settle();
  await shot('03-pair-wrong');
  check(`${scheme}: a wrong PIN says how many tries are left`, /4 tries left/.test(await text()), await text());
  await type('.pin-input', '123456');
  await until(async () => (await view()).includes('view-save'));
  await settle();
  check(`${scheme}: the right PIN goes straight on to the form`, true);

  await open('/r/save-new', { paired: true });
  await shot('04-save');
  check(`${scheme}: paired save shows the form`, (await view()).includes('view-save'));
  check(`${scheme}: save is off until there's a password`, await run('document.querySelector("button[type=submit]").disabled'));
  await type('#f-pass', 'correct horse battery');
  await run('document.querySelector(".reveal").click()');
  await settle();
  await shot('05-save-filled');
  check(`${scheme}: the eye shows the password`, await run('document.querySelector("#f-pass").type === "text"'));

  await open('/r/save-existing', { paired: true });
  await shot('06-save-existing');
  check(`${scheme}: an existing password says unchanged and save is on`, (await run('document.querySelector("#f-pass").placeholder')) === 'unchanged' && !(await run('document.querySelector("button[type=submit]").disabled')));

  await open('/r/save-2fa', { paired: true });
  await shot('07-save-2fa');
  await click('SMS or email');
  await settle();
  await shot('08-save-2fa-sms');
  check(`${scheme}: SMS hides the key field`, await run('document.querySelector(".otp-row").hidden'));
  await click('Authenticator');
  await type('#f-pass', 'hunter22');
  await type('#f-otp', 'nope');
  await run('document.querySelector("form").requestSubmit()');
  await until(async () => /isn’t a 2FA setup key|isn't a 2FA setup key/.test(await text()));
  await settle();
  await shot('09-save-bad-key');
  check(`${scheme}: a bad key shows otto's message under the 2FA field`, await run('!document.querySelector(".group .error").hidden'));

  await open('/r/save-only-2fa', { paired: true });
  await shot('10-save-only-2fa');
  check(`${scheme}: 2FA only has no username row`, !(await run('!!document.querySelector("#f-user")')));

  await open('/r/save-app', { paired: true });
  await shot('11-save-app');
  check(`${scheme}: a Mac app login names the app`, /the docker app/.test(await text()));

  await open('/r/approve', { paired: true });
  await shot('12-approve');
  check(`${scheme}: approve asks the question`, /Let claude via T3 Code fill GitHub’s login in the browser\?/.test(await text()), await text());
  await type('.pin-input', '000000');
  await click('Allow');
  await until(async () => /tries left/.test(await text()));
  await sleep(120);
  await shot('13-approve-wrong');
  for (const [p, left] of [['111111', '3 tries'], ['222222', '2 tries'], ['333333', 'one more wrong one']]) {
    await type('.pin-input', p);
    await click('Allow');
    await until(async () => (await text()).includes(left));
  }
  await settle();
  await shot('14-approve-last-try');
  check(`${scheme}: the last try warns`, true);
  await type('.pin-input', '444444');
  await click('Allow');
  await until(async () => /remote is off/.test(await text()));
  await settle();
  await shot('15-locked');
  check(`${scheme}: 5 wrong PINs lock it`, true);

  await open('/r/approve');
  await shot('16-approve-unpaired');
  check(`${scheme}: unpaired approve says the PIN pairs too`, /also pairs this phone/.test(await text()));

  await open('/r/approve-card', { paired: true });
  await shot('17-approve-card');
  await open('/r/approve-unverified', { paired: true });
  await shot('18-approve-unverified');
  check(`${scheme}: an unverified caller gets a warning`, /couldn’t check who this is/.test(await text()));
  await open('/r/approve-change', { paired: true });
  await shot('18b-approve-change');
  check(`${scheme}: a change asks about it and hides the new value`, /Let codex change GitHub’s password\?/.test(await text()) && /new password/.test(await text()) && !(await text()).includes('PREVIEW-n3w-pa55word'), await text());
  await run('document.querySelector(".change .reveal").click()');
  await settle();
  await shot('18c-approve-change-shown');
  check(`${scheme}: the eye shows the new value`, (await text()).includes('PREVIEW-n3w-pa55word'));
  await run('document.querySelector(".change .reveal").click()');
  check(`${scheme}: and hides it again`, !(await text()).includes('PREVIEW-n3w-pa55word'));
  await open('/r/approve-change-2fa', { paired: true });
  await shot('18d-approve-change-2fa');
  check(`${scheme}: a new 2FA secret is named, no eye`, /new 2FA secret/.test(await text()) && /from the QR code for GitHub/.test(await text()) && !(await run('!!document.querySelector(".change .reveal")')));
  await open('/r/approve-command', { paired: true });
  await shot('18e-approve-command');
  check(`${scheme}: a command shows as it runs, with the agent's reason`, /Let claude run this command\?/.test(await text()) && (await text()).includes('networksetup -setdnsservers Wi-Fi 1.1.1.1 1.0.0.1 && dscacheutil') && /switch Wi-Fi DNS to Cloudflare/.test(await text()) && /in ~\/website/.test(await text()), await text());
  await open('/r/approve-command-fill', { paired: true });
  await shot('18f-approve-command-fill');
  check(`${scheme}: blanks stand out in the command, and each has a field`, (await run('document.querySelectorAll(".blank-mark").length')) === 2 && (await run('document.querySelectorAll(".blank-input input").length')) === 2);
  check(`${scheme}: a secret blank is hidden, the other isn't`, (await run('[...document.querySelectorAll(".blank-input input")].map((i) => i.type).join()')) === 'text,password');
  await type('.pin-input', '123456');
  await click('Allow');
  check(`${scheme}: nothing goes out with a blank empty`, /fill in apple id/.test(await text()) && !(await mock('/mock/log')).some((p) => p.path.endsWith('/approve')));
  await type('.blank-field input[type=text]', 'me@example.com');
  await type('.blank-field input[type=password]', 'abcd-efgh-ijkl');
  await run('document.querySelector(".blank-keep input").click()');
  await shot('18g-approve-command-filled');
  const filled = await text();
  check(`${scheme}: what's typed shows in the command, a secret as dots`, filled.includes('--apple-id me@example.com') && filled.includes('--password ••••••••••••') && !filled.includes('abcd-efgh'));
  await run('document.querySelector(".blank-field .reveal").click()');
  check(`${scheme}: the eye shows the secret, in the command too`, (await text()).includes('--password abcd-efgh-ijkl'));
  await run('document.querySelector(".blank-field .reveal").click()');
  await click('Allow');
  await until(async () => (await view()).includes('view-done'));
  const sent = (await mock('/mock/log')).filter((p) => p.path.endsWith('/approve')).at(-1);
  check(`${scheme}: it sends the PIN and the values, in order`, sent.body === JSON.stringify({ pin: '123456', values: ['me@example.com', 'abcd-efgh-ijkl'], remember: [true, false] }), JSON.stringify(sent));
  await open('/r/approve-command-saved', { paired: true });
  await shot('18h-approve-command-saved');
  const kept = await text();
  check(`${scheme}: what's remembered is ready: the value shows, a secret as dots, and nothing needs typing`, kept.includes('--apple-id kept@example.com') && kept.includes('--password ••••••••••••') && (await run('document.querySelectorAll(".blank-keep input:checked").length')) === 2 && (await run('document.querySelector(".blank-field input[type=password]").placeholder')) === 'saved');
  await type('.pin-input', '123456');
  await click('Allow');
  await until(async () => (await view()).includes('view-done'));
  const reused = (await mock('/mock/log')).filter((p) => p.path.endsWith('/approve')).at(-1);
  check(`${scheme}: it sends no secret back: otto has it`, reused.body === JSON.stringify({ pin: '123456', values: ['kept@example.com', ''], remember: [true, true] }), JSON.stringify(reused));
  await open('/r/approve-command-elsewhere', { paired: true });
  await shot('18i-approve-command-elsewhere');
  check(`${scheme}: a secret saved for another command isn't used until the user says so`, (await text()).includes('it’s saved for xcrun notarytool store-credentials') && (await run('document.querySelector(".blank-reuse input").checked')) === false && (await text()).includes('--password app-specific password'));
  await type('.pin-input', '123456');
  await click('Allow');
  check(`${scheme}: empty and not chosen, it still needs filling in`, !(await view()).includes('view-done') && (await run('document.querySelector(".error:not([hidden])") !== null')) === true);
  await run('document.querySelector(".blank-reuse input").click()');
  check(`${scheme}: chosen, the field locks and the command shows dots`, (await run('document.querySelector(".blank-field input.mono").disabled')) === true && (await text()).includes('--password ••••••••••••'));
  await shot('18j-approve-command-reuse');
  await click('Allow');
  await until(async () => (await view()).includes('view-done'));
  const chosen = (await mock('/mock/log')).filter((p) => p.path.endsWith('/approve')).at(-1);
  check(`${scheme}: it says which blank to use it for, and sends no secret`, chosen.body === JSON.stringify({ pin: '123456', values: [''], remember: [false], reuse: [true] }), JSON.stringify(chosen));
  await open('/r/soon', { paired: true });
  await shot('19-soon');
  check(`${scheme}: under 90 s counts seconds`, /expires in \d+ s/.test(await text()));

  // endings
  await open('/r/save-new', { paired: true });
  await type('#f-pass', 'correct horse battery');
  await run('document.querySelector("form").requestSubmit()');
  await until(async () => (await view()).includes('view-done'));
  await settle();
  await shot('20-saved');
  check(`${scheme}: saved`, /^saved/.test(await text()));

  await open('/r/approve', { paired: true });
  await type('.pin-input', '123456');
  await click('Allow');
  await until(async () => /allowed/.test(await text()));
  await settle();
  await shot('21-allowed');
  check(`${scheme}: allowed`, true);

  await open('/r/approve', { paired: true });
  await click('Don’t allow');
  await until(async () => /you said no/.test(await text()));
  await settle();
  await shot('22-declined');
  check(`${scheme}: declined`, true);

  for (const [p, name, re] of [
    ['/r/expired', '23-expired', /this link expired/],
    ['/r/answered-mac', '24-answered-mac', /already saved[\s\S]*at the Mac/],
    ['/r/answered-phone', '25-answered-phone', /already allowed[\s\S]*on ipad-pro/],
    ['/r/gone', '26-gone', /doesn’t work/],
    ['/r/not-yours', '27-not-yours', /own devices on Tailscale/],
    ['/r/this-mac', '28-this-mac', /open it on your phone/],
    ['/r/locked', '29-locked', /remote is off/],
  ]) {
    await open(p, { paired: true });
    await shot(name);
    check(`${scheme}: ${name.slice(3)}`, re.test(await text()), await text());
  }

  // the Mac answers while the form is open
  await open('/r/flip', { paired: true });
  check(`${scheme}: flip starts as the form`, (await view()).includes('view-save'));
  await until(async () => /already saved/.test(await text()), 12000);
  await settle();
  await shot('30-answered-while-open');
  check(`${scheme}: a Mac-side answer flips the open page`, /at the Mac/.test(await text()));

  // otto unreachable
  offline = true;
  await send('Fetch.enable', { patterns: [{ urlPattern: '*' }] });
  await open('/r/save-new', { paired: true });
  await shot('31-offline');
  check(`${scheme}: unreachable says so`, /can’t reach otto/.test(await text()));
  offline = false;
  await click('Try again');
  await until(async () => (await view()).includes('view-save'));
  check(`${scheme}: try again recovers`, true);
  await send('Fetch.disable');
}

// ---- what the page sends ---------------------------------------------------------

await open('/r/save-2fa', { paired: true });
await type('#f-user', '  alfa@example.com ');
await type('#f-pass', 'pw with spaces ');
await type('#f-otp', 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP');
await run('document.querySelector("form").requestSubmit()');
await until(async () => (await view()).includes('view-done'));
let log = await mock('/mock/log');
let last = log.filter((e) => e.path.startsWith('/api/')).pop();
check('save posts JSON', last.content_type === 'application/json', last.content_type);
check('save sends its origin', last.origin === site, last.origin);
check('save sends the device cookie', last.cookie);
check(
  'save body is username, password, two_factor, otp',
  JSON.stringify(JSON.parse(last.body)) === JSON.stringify({ username: 'alfa@example.com', password: 'pw with spaces ', two_factor: 'app', otp: 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP' }),
  last.body,
);

await open('/r/save-2fa', { paired: true });
await type('#f-pass', 'x');
await click('No 2FA');
await run('document.querySelector("form").requestSubmit()');
await until(async () => (await view()).includes('view-done'));
log = await mock('/mock/log');
last = log.filter((e) => e.path.startsWith('/api/')).pop();
check('no 2FA sends two_factor none and otp null', JSON.stringify(JSON.parse(last.body)) === JSON.stringify({ username: '', password: 'x', two_factor: 'none', otp: null }), last.body);

await open('/r/save-only-2fa', { paired: true });
await type('#f-otp', 'JBSW Y3DP EHPK 3PXP');
await run('document.querySelector("form").requestSubmit()');
await until(async () => (await view()).includes('view-done'));
log = await mock('/mock/log');
last = log.filter((e) => e.path.startsWith('/api/')).pop();
check('2FA only leaves username and password null', JSON.stringify(JSON.parse(last.body)) === JSON.stringify({ username: null, password: null, two_factor: 'app', otp: 'JBSW Y3DP EHPK 3PXP' }), last.body);

await open('/r/approve');
await type('.pin-input', '123456');
await click('Allow');
await until(async () => /allowed/.test(await text()));
log = (await mock('/mock/log')).filter((e) => e.path.startsWith('/api/'));
check('unpaired approve pairs, then approves, with the same PIN', log.length === 2 && log[0].path === '/api/pair' && log[0].body === '{"pin":"123456"}' && log[1].path === '/api/r/approve/approve' && log[1].body === '{"pin":"123456"}', JSON.stringify(log));
check('approve sends the cookie it just got', log[1].cookie);

await open('/r/save-new', { paired: true });
await click('Not now');
await until(async () => /you said no/.test(await text()));
log = (await mock('/mock/log')).filter((e) => e.path.startsWith('/api/') && e.origin);
check('not now declines with {}', log.length === 1 && log[0].path === '/api/r/save-new/decline' && log[0].body === '{}', JSON.stringify(log));

// the device was removed on the Mac: the page asks to pair again and keeps the request
await open('/r/save-new', { paired: true });
await send('Network.clearBrowserCookies');
await type('#f-pass', 'x');
await run('document.querySelector("form").requestSubmit()');
await until(async () => (await view()).includes('view-pair'));
check('a lost pairing goes back to pairing', /isn’t paired anymore/.test(await text()), await text());

// agent text is text: markup in a note stays visible as typed
await open('/r/save-new', { paired: true });
const injected = await run(`(() => { const p = document.querySelector('.bubble'); return p.children.length === 0; })()`);
check('the agent note is plain text', injected);

check('no script errors or CSP violations', problems.length === 0, problems.join(' | '));
const csp = await run('window.__csp');
check('no CSP violations on the last page', csp.length === 0, csp.join(', '));

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
