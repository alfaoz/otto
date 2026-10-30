// otto extension: the only thing that can put a secret into a web page.
// It talks to the otto app through Chrome's native messaging (dev.alfaoz.otto), never to pages.

const HOST = 'dev.alfaoz.otto';
let port = null;
let retryMs = 1000;
// what the toolbar icon and its popup show. state: checking, no_helper (Chrome can't start otto's helper),
// not_running (the helper's up, the app isn't), locked, refused (the app doesn't trust this browser), connected
let status = { state: 'checking' };

function connect() {
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    setStatus({ state: 'no_helper', detail: e.message });
    return retry();
  }
  port.onMessage.addListener(onMessage);
  port.onDisconnect.addListener(() => {
    const why = chrome.runtime.lastError?.message;
    console.warn('otto: helper disconnected', why);
    port = null;
    setStatus({ state: 'no_helper', detail: why });
    retry();
  });
}

function retry() {
  setTimeout(connect, retryMs);
  retryMs = Math.min(retryMs * 2, 60000);
}

const TITLES = {
  checking: 'otto: checking',
  no_helper: 'otto: Chrome can\'t start otto\'s helper',
  not_running: 'otto: the otto app isn\'t running',
  locked: 'otto: locked',
  refused: 'otto: otto doesn\'t trust this browser',
  relaunch: 'otto: relaunch this browser',
  connected: 'otto: connected',
};

function setStatus(s) {
  status = s;
  const on = s.state === 'connected';
  if (on) retryMs = 1000;
  chrome.action.setBadgeText({ text: on ? '' : '!' });
  chrome.action.setBadgeBackgroundColor({ color: '#b3261e' });
  chrome.action.setTitle({ title: TITLES[s.state] });
  // an open popup redraws; with none open nobody's listening, and that's fine
  chrome.runtime.sendMessage({ type: 'status', status }).catch(() => {});
}

function serviceStatus(d) {
  if (d?.connected) return { state: 'connected', browser: d.browser || null };
  if (!d?.error) return { state: 'not_running' };
  const { code, message } = d.error;
  return { state: code === 'locked' || code === 'relaunch' ? code : 'refused', detail: message };
}

// The app keeps this unpacked extension's files current. Chrome keeps running the code it loaded,
// so compare the files on disk with what this worker started from and reload when they differ.
const fingerprint = async () => {
  const texts = await Promise.all(['manifest.json', 'background.js', 'offscreen.html', 'offscreen.js', 'popup.html', 'popup.js', 'popup.css'].map((f) => fetch(chrome.runtime.getURL(f), { cache: 'no-store' }).then((r) => r.text())));
  return texts.join('\u0000');
};
const loaded = fingerprint().catch(() => null);
async function reloadIfUpdated() {
  try {
    const [then, now] = [await loaded, await fingerprint()];
    if (then && now !== then) chrome.runtime.reload();
  } catch {}
}

async function onMessage(msg) {
  if (msg.type === 'event') {
    if (msg.event === 'service') {
      setStatus(serviceStatus(msg.data));
      if (msg.data?.connected) reloadIfUpdated();
    }
    return;
  }
  if (msg.type !== 'req') return;
  let reply;
  try {
    reply = { type: 'res', id: msg.id, ok: true, result: await handle(msg.op, msg.args || {}) };
  } catch (e) {
    reply = { type: 'res', id: msg.id, ok: false, error: { code: e.code || 'error', message: e.message || String(e) } };
  }
  port?.postMessage(reply);
}

// ---- toolbar icon ---------------------------------------------------------------------------
// At rest it's otto's bare monogram in Chrome's own icon color for light or dark mode (a hidden
// offscreen page reports which). While otto writes into a tab, that tab's icon becomes the app's tile,
// until a moment after it's done.

const ICON_SIZES = [16, 24, 32];
const icon = (name) => Object.fromEntries(ICON_SIZES.map((n) => [n, `icons/toolbar-${name}-${n}.png`]));
const resting = () => icon(dark ? 'dark' : 'light');
const LINGER_MS = 2000;
let dark = false;
// tab id -> { n: writes running in it, timer: puts its resting icon back }
const busy = new Map();

// a tab can close at any moment, and then setting its icon fails; nothing to do about that
const setIcon = (details) => chrome.action.setIcon(details).catch(() => {});

// `changed`: the mode switched while tabs may carry their own icon (any otto wrote into), so each
// open tab gets the new one, not just the default
async function setScheme(isDark, changed) {
  dark = !!isDark;
  setIcon({ path: resting() });
  if (!changed) return;
  for (const t of await chrome.tabs.query({})) if (!busy.has(t.id)) setIcon({ tabId: t.id, path: resting() });
}

async function writing(tabId, work) {
  const b = busy.get(tabId) || { n: 0, timer: null };
  busy.set(tabId, b);
  clearTimeout(b.timer);
  if (b.n++ === 0) setIcon({ tabId, path: icon('active') });
  try {
    return await work();
  } finally {
    if (--b.n === 0) {
      b.timer = setTimeout(() => {
        busy.delete(tabId);
        setIcon({ tabId, path: resting() });
      }, LINGER_MS);
    }
  }
}

// a page load (a submitted login) resets the tab's own icon, so a tab otto is still busy in gets it back
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status && busy.has(tabId)) setIcon({ tabId, path: icon('active') });
});
chrome.tabs.onRemoved.addListener((tabId) => {
  clearTimeout(busy.get(tabId)?.timer);
  busy.delete(tabId);
});

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (sender.id !== chrome.runtime.id) return;
  if (msg?.type === 'scheme' && sender.url?.endsWith('/offscreen.html')) setScheme(msg.dark, msg.changed);
  if (sender.url?.endsWith('/popup.html')) {
    if (msg?.type === 'status?') reply(status);
    // only the helper can start the app; without it there's nothing to ask
    if (msg?.type === 'open_app') port?.postMessage({ type: 'open_app' });
  }
});

async function watchScheme() {
  try {
    const open = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
    if (!open.length) {
      // it reports the mode once it has loaded
      await chrome.offscreen.createDocument({ url: 'offscreen.html', reasons: ['MATCH_MEDIA'], justification: 'colors the toolbar icon for light or dark mode' });
      return;
    }
    const r = await chrome.runtime.sendMessage({ type: 'scheme?' });
    if (r) setScheme(r.dark);
  } catch (e) {
    // e.g. another start of this worker made the page a moment ago; that one reports
    console.warn('otto: light/dark watcher', e?.message);
  }
}

// the page checks every couple of seconds, but timers in a hidden page can slow to once a minute, so
// coming back to Chrome (after switching the Mac's appearance, say) asks right away
chrome.windows.onFocusChanged.addListener(async (w) => {
  if (w === chrome.windows.WINDOW_ID_NONE) return;
  const r = await chrome.runtime.sendMessage({ type: 'scheme?' }).catch(() => null);
  // no answer: the page is gone (Chrome can close it), so open it again
  if (!r) return watchScheme();
  if (r.dark !== dark) setScheme(r.dark, true);
});

function fail(code, message) {
  const e = new Error(message);
  e.code = code;
  return e;
}


// localhost, 127.x.x.x and ::1 are all this machine, so they count as one site
const isLoopback = (h) => h === 'localhost' || h === '[::1]' || h === '::1' || /^127\.\d+\.\d+\.\d+$/.test(h);

function matches(host, sites) {
  host = host.toLowerCase().replace(/^www\./, '');
  if (isLoopback(host) && sites.some(isLoopback)) return true;
  return sites.some((s) => host === s || host.endsWith('.' + s));
}

// The most recently used tab whose site belongs to the entry. Plain http only on loopback, or when
// the service says bypass is on for the entry (`http`): the user allowed it any site.
async function findTab(sites, http = false) {
  const tabs = await chrome.tabs.query({});
  const ok = tabs.filter((t) => {
    try {
      const u = new URL(t.url);
      return (u.protocol === 'https:' || u.protocol === 'http:') && matches(u.hostname, sites);
    } catch {
      return false;
    }
  });
  if (!ok.length) throw fail('no_tab', `no open tab for ${sites.join(', ')}. open the login page in Chrome first`);
  ok.sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0));
  const tab = ok[0];
  const u = new URL(tab.url);
  if (u.protocol === 'http:' && !isLoopback(u.hostname) && !http) throw fail('insecure', `${u.hostname} isn't using https, otto won't fill it`);
  return tab;
}

async function run(tabId, func, args) {
  const [res] = await chrome.scripting.executeScript({ target: { tabId, frameIds: [0] }, func, args });
  const r = res?.result;
  if (!r) throw fail('page', 'the page didn\'t respond');
  if (r.error) throw fail(r.error, r.message);
  return r;
}

// how long submitForm waits for a check that solves itself (Turnstile, Friendly Captcha) or a button that
// wakes up; the service gives the whole fill 20 seconds
const SUBMIT_WAIT_MS = 8000;

// Login forms often live in a frame (Apple's sign-in is one). Ask every frame of the tab where the
// fields are without touching them, then fill only the best frame. A frame on another site never
// matches: each frame checks its own address against the entry's sites.
async function runInForm(tabId, func, args) {
  const probes = await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, func, args: [...args, true] });
  const ok = probes.filter((p) => p.result && !p.result.error && p.result.score > 0);
  if (!ok.length) {
    const top = probes.find((p) => p.frameId === 0)?.result;
    if (top?.error) throw fail(top.error, top.message);
    const other = probes.find((p) => p.result?.error && p.result.error !== 'wrong_site')?.result;
    if (other) throw fail(other.error, other.message);
    throw fail('no_field', top?.message || 'no login form on this page');
  }
  ok.sort((a, b) => b.result.score - a.result.score || (a.frameId === 0 ? -1 : b.frameId === 0 ? 1 : 0));
  const best = ok[0];
  const [res] = await chrome.scripting.executeScript({ target: { tabId, frameIds: [best.frameId] }, func, args: [...args, false] });
  const r = res?.result;
  if (!r) throw fail('page', 'the page didn\'t respond');
  if (r.error) throw fail(r.error, r.message);
  // args[2] is `submit`: the filler left the button for submitForm, which looks at the page before clicking
  let sent = {};
  if (args[2]) {
    try {
      const [s] = await chrome.scripting.executeScript({ target: { tabId, frameIds: [best.frameId] }, func: submitForm, args: [SUBMIT_WAIT_MS] });
      sent = s?.result || { submitted: false, held: 'the page didn\'t answer when otto tried to submit' };
    } catch {
      sent = { submitted: false, held: 'the page changed while otto was submitting, look at it before going on' };
    }
  }
  const tab = await chrome.tabs.get(tabId);
  return { ...r, ...sent, frame_url: r.url, url: tab.url };
}

// A checkout's card fields are often spread over frames from the payment provider (Stripe Elements
// puts the number, expiry and CVC in a frame each). Ask every frame what it has, then fill each of
// them, the page itself first. Each frame checks its own address and its parents': the site itself,
// or a payment provider's frame inside the site, never anything else.
async function fillCardFrames(tabId, sites, providers, values) {
  const probes = await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, func: fillCard, args: [sites, providers, values, [], true] });
  const ok = probes.filter((p) => p.result && !p.result.error && p.result.fields.length);
  if (!ok.length) {
    const top = probes.find((p) => p.frameId === 0)?.result;
    if (top?.error) throw fail(top.error, top.message);
    throw fail('no_field', 'no card form on this page');
  }
  ok.sort((a, b) => (a.frameId === 0 ? -1 : b.frameId === 0 ? 1 : 0));
  const filled = [];
  const frames = [];
  for (const p of ok) {
    const [res] = await chrome.scripting.executeScript({ target: { tabId, frameIds: [p.frameId] }, func: fillCard, args: [sites, providers, values, filled, false] });
    const r = res?.result;
    if (!r || r.error || !r.filled.length) continue;
    filled.push(...r.filled);
    frames.push(r.url);
  }
  if (!filled.length) throw fail('no_field', 'no card form on this page');
  const tab = await chrome.tabs.get(tabId);
  return { url: tab.url, frames, filled };
}

async function handle(op, args) {
  switch (op) {
    case 'ping':
      return { pong: true };
    case 'has_tab': {
      if (!args.sites?.length) return { found: (await chrome.tabs.query({ active: true, lastFocusedWindow: true })).length > 0 };
      try {
        await findTab(args.sites, !!args.http);
        return { found: true };
      } catch (e) {
        if (e.code === 'no_tab') return { found: false };
        throw e;
      }
    }
    case 'fill': {
      const tab = await findTab(args.sites || [], !!args.http);
      return writing(tab.id, () => runInForm(tab.id, fillLogin, [args.sites, args.values || {}, !!args.submit, !!args.http]));
    }
    case 'fill_code': {
      const tab = await findTab(args.sites || [], !!args.http);
      return writing(tab.id, () => runInForm(tab.id, fillCode, [args.sites, String(args.code), !!args.submit, !!args.http]));
    }
    case 'probe_card': {
      // which card fields the checkout has, before the user is asked (`values` are stand-ins)
      const tab = await findTab(args.sites || []);
      const probes = await chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, func: fillCard, args: [args.sites, args.providers || [], args.values || {}, [], true] });
      return { fields: [...new Set(probes.flatMap((p) => (p.result && !p.result.error ? p.result.fields : [])))] };
    }
    case 'fill_card': {
      const tab = await findTab(args.sites || []);
      return writing(tab.id, () => fillCardFrames(tab.id, args.sites, args.providers || [], args.values || {}));
    }
    case 'capture_qr': {
      let tab;
      if (args.sites?.length) tab = await findTab(args.sites);
      else [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
      if (!tab) throw fail('no_tab', 'no tab to read the QR code from');
      if (!tab.active) await chrome.tabs.update(tab.id, { active: true });
      const r = await run(tab.id, revealQR, []);
      await new Promise((ok) => setTimeout(ok, 400));
      const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
      return { url: r.url, found: r.found, png: dataUrl.slice(dataUrl.indexOf(',') + 1) };
    }
    default:
      throw fail('bad_request', `unknown op ${op}`);
  }
}

// ---- injected into the page (each function must be self-contained) ----------------------

// Shared by both fillers (injected functions can't share code, so each defines these again):
// the page check, a visibility test, a search that also looks inside web components' shadow
// roots (Reddit's login is one), and a value setter that frameworks like React notice.

function fillLogin(sites, values, submit, http, dry) {
  const host = location.hostname.toLowerCase().replace(/^www\./, '');
  const loop = (h) => h === 'localhost' || h === '[::1]' || h === '::1' || /^127\.\d+\.\d+\.\d+$/.test(h);
  if (!(loop(host) && sites.some(loop)) && !sites.some((s) => host === s || host.endsWith('.' + s))) return { error: 'wrong_site', message: `this page is ${host}` };
  if (location.protocol !== 'https:' && !loop(host) && !http) return { error: 'insecure', message: `${host} isn't using https, otto won't fill it` };
  const deep = (sel, root = document, out = []) => {
    for (const el of root.querySelectorAll('*')) {
      if (el.matches(sel)) out.push(el);
      if (el.shadowRoot) deep(sel, el.shadowRoot, out);
    }
    return out;
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    const st = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && st.visibility !== 'hidden' && st.display !== 'none' && !el.disabled && !el.readOnly;
  };
  const set = (el, v) => {
    el.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  };
  const describe = (i) => [i.name, i.id, i.placeholder, i.getAttribute('aria-label'), i.autocomplete].join(' ');
  const inputs = deep('input').filter(visible);
  const pw = inputs.find((i) => i.type === 'password' && i.autocomplete !== 'new-password') || inputs.find((i) => i.type === 'password');
  const texts = inputs.filter((i) => ['text', 'email', 'tel'].includes(i.type));
  let user = inputs.find((i) => (i.autocomplete || '').split(/\s+/).includes('username')) || texts.find((i) => i.type === 'email');
  // the text box right before the password box (in page order, shadow roots included)
  if (!user && pw) user = texts.filter((i) => inputs.indexOf(i) < inputs.indexOf(pw)).pop();
  if (!user) user = texts.find((i) => /user|login|email|e-?posta|account|kullan|phone|telefon/i.test(describe(i)));
  const can = { username: values.username != null && !!user, password: values.password != null && !!pw };
  if (dry) {
    const score = (can.password ? 2 : 0) + (can.username ? 1 : 0);
    return score ? { score, url: location.href } : { score: 0, message: 'no login form on this page' };
  }
  const filled = [];
  if (can.username) {
    set(user, values.username);
    filled.push('username');
  }
  if (can.password) {
    set(pw, values.password);
    filled.push('password');
  }
  if (!filled.length) {
    const msg = !user && !pw ? 'no login form on this page' : values.password != null && !pw ? 'no password field on this page' : 'no username field on this page';
    return { error: 'no_field', message: msg };
  }
  // submitting is submitForm's job, after it looks at the page; it finds the button here
  if (submit) {
    const el = pw && filled.includes('password') ? pw : user;
    const form = el.form;
    const btn =
      (form && form.querySelector('button[type=submit], input[type=submit], button:not([type])')) ||
      deep('button, input[type=submit], [role=button]').find((b) =>
        visible(b) && /^(log ?in|sign ?in|continue|next|submit|giriş|giris|devam|ileri|oturum aç)/i.test((b.innerText || b.value || '').trim()),
      );
    globalThis.ottoSubmit = { btn, form, mine: [user, pw].filter(Boolean) };
  }
  return { url: location.href, filled, submitted: false };
}

function fillCode(sites, code, submit, http, dry) {
  const host = location.hostname.toLowerCase().replace(/^www\./, '');
  const loop = (h) => h === 'localhost' || h === '[::1]' || h === '::1' || /^127\.\d+\.\d+\.\d+$/.test(h);
  if (!(loop(host) && sites.some(loop)) && !sites.some((s) => host === s || host.endsWith('.' + s))) return { error: 'wrong_site', message: `this page is ${host}` };
  if (location.protocol !== 'https:' && !loop(host) && !http) return { error: 'insecure', message: `${host} isn't using https, otto won't fill it` };
  const deep = (sel, root = document, out = []) => {
    for (const el of root.querySelectorAll('*')) {
      if (el.matches(sel)) out.push(el);
      if (el.shadowRoot) deep(sel, el.shadowRoot, out);
    }
    return out;
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    const st = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && st.visibility !== 'hidden' && st.display !== 'none' && !el.disabled && !el.readOnly;
  };
  const set = (el, v) => {
    el.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  };
  const describe = (i) => [i.name, i.id, i.placeholder, i.getAttribute('aria-label'), i.className].join(' ');
  const inputs = deep('input').filter(visible).filter((i) => ['text', 'tel', 'number'].includes(i.type));
  const boxes = inputs.filter((i) => i.maxLength === 1);
  // a lone unlabeled box is the code field, unless this is a login form (its username box)
  const login = deep('input[type=password]').some(visible);
  const userish = (i) => /username|email/.test(i.autocomplete || '') || /user|login|mail|e-?posta|kullan|phone|telefon/i.test(describe(i));
  const field =
    inputs.find((i) => i.autocomplete === 'one-time-code') ||
    inputs.find((i) => i.maxLength !== 1 && /otp|totp|2fa|mfa|one.?time|verif|auth|security|token|code|kod|doğrula/i.test(describe(i))) ||
    (inputs.length === 1 && !login && !userish(inputs[0]) ? inputs[0] : null);
  const split = boxes.length >= code.length && (!field || field.maxLength === 1);
  if (dry) return split || field ? { score: 1, url: location.href } : { score: 0, message: 'no 2FA code field on this page' };
  let target;
  if (split) {
    code.split('').forEach((d, k) => set(boxes[k], d));
    target = boxes[0];
  } else if (field) {
    set(field, code);
    target = field;
  } else {
    return { error: 'no_field', message: 'no 2FA code field on this page' };
  }
  if (submit) {
    const form = target.form;
    const btn =
      (form && form.querySelector('button[type=submit], input[type=submit], button:not([type])')) ||
      deep('button, input[type=submit], [role=button]').find((b) =>
        visible(b) && /^(verify|confirm|continue|submit|next|log ?in|sign ?in|doğrula|onayla|devam|giriş)/i.test((b.innerText || b.value || '').trim()),
      );
    globalThis.ottoSubmit = { btn, form, mine: split ? boxes : [field] };
  }
  return { url: location.href, filled: ['code'], submitted: false };
}

// Submits what fillLogin or fillCode just filled (they leave the button in `ottoSubmit`, which lives in
// the extension's own world, not the page's), but looks first. A captcha or a Cloudflare check that isn't
// done, a box the form needs ticked or a field it rejects would make the click fail or worse, so then it
// doesn't click and says why (`held`), and the agent takes it from there. Turnstile and Friendly Captcha
// usually solve themselves in a few seconds, and a disabled button often wakes up once they do, so those
// get up to `waitMs`. Invisible reCAPTCHA (v3, enterprise) gets its token in the site's own click handler,
// so it doesn't hold anything back. Clicks the button rather than submitting the form, so the site's
// handlers run.
async function submitForm(waitMs) {
  const t = globalThis.ottoSubmit;
  delete globalThis.ottoSubmit;
  if (!t || (t.btn && !t.btn.isConnected) || (t.form && !t.form.isConnected)) return { submitted: false, held: 'the page changed before otto could submit' };
  const { btn, form, mine } = t;
  if (!btn && !form) return { submitted: false, held: 'there is no button to submit with' };
  const deep = (sel, root = document, out = []) => {
    for (const el of root.querySelectorAll('*')) {
      if (el.matches(sel)) out.push(el);
      if (el.shadowRoot) deep(sel, el.shadowRoot, out);
    }
    return out;
  };
  const shown = (el) => {
    const r = el.getBoundingClientRect();
    const st = getComputedStyle(el);
    return r.width > 1 && r.height > 1 && st.visibility !== 'hidden' && st.display !== 'none' && +st.opacity !== 0;
  };
  // part of this form, or of no form at all (a widget in some other form on the page isn't ours)
  const ours = (el) => !form || !el.closest('form') || el.closest('form') === form;
  const text = (s) => (s || '').replace(/\s+/g, ' ').trim().slice(0, 60);
  const label = (el) => text((el.labels && el.labels[0]?.innerText) || el.getAttribute('aria-label') || el.closest('label')?.innerText || el.placeholder || el.name);
  const filled = (el) => !!el.value && !el.value.startsWith('.');
  // `waits`: solves itself, so worth waiting for. `invisible`: no widget to do, the click itself fetches the token.
  const widgets = [
    { what: 'a Cloudflare check', box: '.cf-turnstile, iframe[src*="challenges.cloudflare.com"]', token: 'input[name="cf-turnstile-response"]', waits: true },
    { what: 'a Friendly Captcha', box: '.frc-captcha', token: 'input[name="frc-captcha-solution"], input[name="frc-captcha-response"]', waits: true },
    {
      what: 'a reCAPTCHA',
      box: '.g-recaptcha, iframe[src*="/recaptcha/api2/anchor"], iframe[src*="/recaptcha/enterprise/anchor"]',
      token: 'textarea[name="g-recaptcha-response"]',
      invisible: (el) => !!el.closest('.grecaptcha-badge') || el.getAttribute('data-size') === 'invisible' || /[?&#]size=invisible/.test(el.src || ''),
    },
    {
      what: 'an hCaptcha',
      box: '.h-captcha, iframe[src*="hcaptcha.com"]',
      token: 'textarea[name="h-captcha-response"]',
      invisible: (el) => el.getAttribute('data-size') === 'invisible' || /[?&#]size=invisible/.test(el.src || ''),
    },
    { what: 'an Arkose puzzle', box: 'iframe[src*="arkoselabs.com"], iframe[src*="funcaptcha.com"], #FunCaptcha', token: 'input[name="fc-token"], #FunCaptcha-Token, input[name="verification-token"]' },
    { what: 'a GeeTest check', box: '.geetest_holder, .geetest_captcha, .geetest_btn, .geetest_radar_btn', token: 'input[name="geetest_validate"], input[name="captcha_output"]', done: '[class*="geetest_success"]' },
    { what: 'an AWS captcha', box: 'awswaf-captcha' },
  ];
  // what still stands between the form and a working click: [reason, worth waiting for, a check with nothing on screen]
  const blocker = () => {
    let hidden = null;
    for (const w of widgets) {
      const boxes = deep(w.box).filter(ours).filter((el) => !w.invisible?.(el));
      const tokens = w.token ? deep(w.token).filter(ours) : [];
      if (tokens.some(filled) || (w.done && deep(w.done).some(ours))) continue;
      if (boxes.some(shown)) return [`${w.what} on the page isn't done`, !!w.waits];
      // a self-solving check that shows nothing yet (still loading, or interaction-only)
      if (w.waits && (boxes.length || tokens.length)) hidden ||= [`${w.what} on the page isn't done`, true, true];
    }
    // a "type the characters" captcha (on Turkish sites often a "güvenlik kodu")
    const typed = deep('input').filter(ours).find((el) => {
      if (mine.includes(el) || !shown(el) || el.value || !['text', 'tel', 'number'].includes(el.type)) return false;
      return /captcha/i.test([el.name, el.id, el.className, el.placeholder, el.getAttribute('aria-label')].join(' ')) ||
        /g[üu]venlik ?kodu|resimdeki|resimde ?g[öo]r/i.test([el.placeholder, el.getAttribute('aria-label'), label(el)].join(' '));
    });
    if (typed) return ['the page wants a captcha typed in', false];
    if (form) {
      const els = [...form.elements];
      const terms = /terms|agree|accept|kabul|ko[şs]ul|s[öo]zle[şs]me|[şs]art|kvkk|ayd[ıi]nlatma|privacy|gizlilik|policy/i;
      const box = els.find((el) => el.type === 'checkbox' && !el.checked && (el.required || terms.test(label(el)) || /robot/i.test(label(el))));
      if (box) {
        const l = label(box);
        if (/robot/i.test(l)) return ['the form needs the "I\'m not a robot" box ticked', false];
        if (terms.test(l)) return ['the form needs the terms box ticked', false];
        return [l ? `the form needs the "${l}" box ticked` : 'the form needs a box ticked', false];
      }
      // checked without firing the page's "invalid" handlers (form.checkValidity() would fire them)
      const bad = form.noValidate ? null : els.find((el) => el.willValidate && !el.validity.valid);
      if (bad) {
        const l = label(bad) || bad.name || 'a field';
        return [bad.validity.valueMissing ? `the form says "${l}" is empty` : `the form says "${l}" isn't right`, false];
      }
    }
    if (hidden) return hidden;
    if (btn && (btn.disabled || btn.getAttribute('aria-disabled') === 'true')) return ['the submit button is still disabled', true];
    return null;
  };
  const end = Date.now() + waitMs;
  let b = blocker();
  while (b && b[1] && Date.now() < end) {
    await new Promise((ok) => setTimeout(ok, 250));
    if (!(btn || form).isConnected) return { submitted: false, held: 'the page changed before otto could submit' };
    b = blocker();
  }
  // a self-solving check that never showed anything may only run when the site calls it on submit, so
  // click anyway (unless the button is off, which means the site is still waiting on it)
  const off = btn && (btn.disabled || btn.getAttribute('aria-disabled') === 'true');
  if (b && (!b[2] || off)) return { submitted: false, held: b[0] };
  if (btn) btn.click();
  else form.requestSubmit();
  return { submitted: true };
}

// `skip`: fields another frame already filled. Never submits: paying is the agent's (and the user's) call.
function fillCard(sites, providers, values, skip, dry) {
  const bare = (h) => h.toLowerCase().replace(/^www\./, '');
  const loop = (h) => h === 'localhost' || h === '[::1]' || h === '::1' || /^127\.\d+\.\d+\.\d+$/.test(h);
  const under = (h, list) => list.some((s) => h === s || h.endsWith('.' + s));
  const mine = (h) => (loop(h) && sites.some(loop)) || under(h, sites);
  const host = bare(location.hostname);
  const top = window === window.top;
  const provider = !top && !mine(host) && under(host, providers);
  if (top ? !mine(host) : !(mine(host) || provider)) return { error: 'wrong_site', message: `this frame is ${host}` };
  // a frame counts only inside the site (a provider frame inside some other site's frame doesn't)
  if (!top && ![...location.ancestorOrigins].every((o) => { const h = bare(new URL(o).hostname); return mine(h) || under(h, providers); })) {
    return { error: 'wrong_site', message: `this frame (${host}) sits inside another site` };
  }
  if (location.protocol !== 'https:' && !loop(host)) return { error: 'insecure', message: `${host} isn't using https, otto won't fill a card there` };
  const deep = (sel, root = document, out = []) => {
    for (const el of root.querySelectorAll('*')) {
      if (el.matches(sel)) out.push(el);
      if (el.shadowRoot) deep(sel, el.shadowRoot, out);
    }
    return out;
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    const st = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && st.visibility !== 'hidden' && st.display !== 'none' && !el.disabled && !el.readOnly;
  };
  const set = (el, v) => {
    el.focus();
    const proto = el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
    el.blur();
  };
  const describe = (el) => [el.name, el.id, el.placeholder, el.getAttribute('aria-label'), el.getAttribute('data-elements-stable-field-name')].join(' ').toLowerCase();
  const tokens = (el) => (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
  // checked in this order, so "expiry month" is a month before it's an expiry
  const kinds = [
    ['number', 'cc-number', /card.?num|cc.?num|credit.?card|kart.?(no|num)|card.?no\b/],
    ['cvc', 'cc-csc', /cvc|cvv|csc|security.?code|g[üu]venlik|card.?code/],
    ['exp_month', 'cc-exp-month', /exp.*(month|mm)|month|\bay\b/],
    ['exp_year', 'cc-exp-year', /exp.*(year|yy)|year|y[ıi]l/],
    ['exp', 'cc-exp', /exp|valid.?thru|son.?kullan|mm ?\/ ?yy|\bskt\b/],
    ['cardholder', 'cc-name', /card.?holder|name.?on.?card|holder.?name|kart.?sahib|cc.?name/],
  ];
  const els = deep('input, select').filter(visible).filter((el) => !['hidden', 'checkbox', 'radio', 'submit', 'button', 'file', 'image', 'search'].includes(el.type));
  const found = {};
  for (const el of els) {
    const k = kinds.find(([name, ac]) => !found[name] && tokens(el).includes(ac)) || kinds.find(([name, , re]) => !found[name] && re.test(describe(el)));
    if (k) found[k[0]] = el;
  }
  // a postal code in the provider's frame is the card's; on the shop's own page it could be the shipping
  // address, so there it has to say billing, or be in the card's form and not say shipping
  const zips = els.filter((el) => !Object.values(found).includes(el) && (tokens(el).includes('postal-code') || /postal|zip|post.?code|posta.?kod/.test(describe(el))));
  const zip = provider
    ? zips[0]
    : zips.find((el) => tokens(el).includes('billing')) ||
      zips.find((el) => found.number && el.form && el.form === found.number.form && !tokens(el).includes('shipping'));
  if (zip) found.postal_code = zip;
  const month = values.exp_month;
  const year = values.exp_year;
  const plan = {
    number: values.number?.replace(/\D/g, ''),
    cvc: values.cvc,
    exp_month: month,
    exp_year: year,
    exp: month && year && `${month}/${year.slice(-2)}`,
    cardholder: values.cardholder,
    postal_code: values.postal_code,
  };
  const todo = Object.keys(found).filter((k) => plan[k] && !skip.includes(k));
  if (dry) return { url: location.href, fields: todo };
  const pick = (sel, wants) => {
    const o = [...sel.options].find((o) => wants.includes(o.value.trim()) || wants.includes(o.text.trim()));
    if (o) set(sel, o.value);
    return !!o;
  };
  const filled = [];
  for (const k of todo) {
    const el = found[k];
    let v = plan[k];
    if (el instanceof HTMLSelectElement) {
      const wants = k === 'exp_month' ? [month, String(+month)] : k === 'exp_year' ? [year, year.slice(-2)] : [v];
      if (pick(el, wants)) filled.push(k);
      continue;
    }
    const hint = describe(el);
    if (k === 'exp_year' && (el.maxLength === 2 || (/\byy\b/.test(hint) && !/yyyy/.test(hint)))) v = year.slice(-2);
    if (k === 'exp' && /yyyy/.test(hint)) v = `${month}/${year}`;
    if (k === 'exp' && el.maxLength === 4) v = `${month}${year.slice(-2)}`;
    set(el, v);
    filled.push(k);
  }
  return { url: location.href, filled };
}

function revealQR() {
  const square = (el) => {
    const r = el.getBoundingClientRect();
    return r.width >= 80 && Math.abs(r.width - r.height) < 16;
  };
  const looksQR = (el) => /qr|otp|2fa|totp|authenticator/i.test(el.outerHTML.slice(0, 400));
  const cands = [...document.querySelectorAll('img, canvas, svg')].filter(square);
  cands.sort((a, b) => looksQR(b) - looksQR(a) || b.getBoundingClientRect().width - a.getBoundingClientRect().width);
  if (cands[0]) cands[0].scrollIntoView({ block: 'center', behavior: 'instant' });
  return { url: location.href, found: !!cands[0] };
}

chrome.runtime.onStartup.addListener(() => {});
chrome.runtime.onInstalled.addListener(() => {});
setStatus({ state: 'checking' });
connect();
watchScheme();
