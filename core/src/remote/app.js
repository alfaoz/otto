// otto remote: the page an agent's link opens on the user's phone (over Tailscale).
// It saves a login the agent asked for, or answers an approval with the user's PIN.
// Everything an agent wrote (names, notes) goes in as text, never as markup.
'use strict';
(function () {
  const app = document.getElementById('app');
  const found = /^\/r\/([A-Za-z0-9_-]+)\/?$/.exec(location.pathname);
  const id = found ? found[1] : null;
  const POLL_MS = 3000;

  let info = null; // the last GET /api/r/<id>
  let deadline = 0; // when the request expires, ms
  let poller = null;
  let busy = false; // a POST is out: don't poll over it
  let live = false; // a request view is up (pair, save, approve): poll and count down

  // ---- dom ----------------------------------------------------------------

  const SVG = 'http://www.w3.org/2000/svg';

  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const kid of kids.flat()) {
      if (kid == null || kid === false) continue;
      el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    }
    return el;
  }

  // line icons on a 24 grid, drawn with the text color
  const ICONS = {
    check: ['M5 12.5l4.5 4.5L19 7.5'],
    x: ['M6.5 6.5l11 11M17.5 6.5l-11 11'],
    clock: ['circle 12 12 8.5', 'M12 7.5V12l3 2'],
    lock: ['M6.5 11h11v8.5h-11z', 'M8.5 11V8a3.5 3.5 0 0 1 7 0v3'],
    eye: ['M2.5 12s3.5-6.5 9.5-6.5S21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z', 'circle 12 12 3'],
    eyeoff: ['M2.5 12s3.5-6.5 9.5-6.5S21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z', 'circle 12 12 3', 'M4 4l16 16'],
    key: ['circle 8 15 4', 'M11 12l8.5-8.5M16 6.5l2.5 2.5'],
    hash: ['M5 9.5h14M5 14.5h14M10 4.5l-2 15M16 4.5l-2 15'],
    message: ['M4.5 5.5h15v10h-9l-4 3.5v-3.5h-2z'],
    shield: ['M12 3.5l7 2.8v5.5c0 4.4-3 7.4-7 8.7-4-1.3-7-4.3-7-8.7V6.3z', 'M9 12l2.2 2.2L15.5 10'],
    minus: ['circle 12 12 8.5', 'M8.5 12h7'],
    alert: ['M12 4l9 15.5H3z', 'M12 10v4', 'M12 17v.01'],
    phone: ['M8 3.5h8a1.5 1.5 0 0 1 1.5 1.5v14a1.5 1.5 0 0 1-1.5 1.5H8A1.5 1.5 0 0 1 6.5 19V5A1.5 1.5 0 0 1 8 3.5z', 'M11 17.5h2'],
    folder: ['M3.5 6.5h6l2 2h9v10h-17z'],
    terminal: ['M4 5.5h16v13H4z', 'M7.5 9.5l3 2.5-3 2.5', 'M12.5 15h4'],
    tray: ['M4 13.5l2.5-8h11l2.5 8v5H4z', 'M4 13.5h4.5l1 2h5l1-2H20'],
    cloud: ['M7 18.5a4 4 0 0 1-.6-7.95A5.5 5.5 0 0 1 17 9a4.5 4.5 0 0 1 .5 9.5z', 'M4 4l16 16'],
  };

  function icon(name, cls) {
    const s = document.createElementNS(SVG, 'svg');
    s.setAttribute('viewBox', '0 0 24 24');
    s.setAttribute('aria-hidden', 'true');
    s.setAttribute('class', 'icon' + (cls ? ' ' + cls : ''));
    for (const d of ICONS[name]) {
      let el;
      if (d.startsWith('circle')) {
        const [, cx, cy, r] = d.split(' ');
        el = document.createElementNS(SVG, 'circle');
        el.setAttribute('cx', cx);
        el.setAttribute('cy', cy);
        el.setAttribute('r', r);
      } else {
        el = document.createElementNS(SVG, 'path');
        el.setAttribute('d', d);
      }
      s.append(el);
    }
    return s;
  }

  function show(name, ...nodes) {
    app.className = 'view view-' + name;
    app.replaceChildren(...nodes.flat().filter(Boolean));
  }

  // ---- words --------------------------------------------------------------

  const unverified = (a) => /^an unverified program/.test(a || '');

  function agentClass(a) {
    if (unverified(a)) return 'agent-unverified';
    const w = (a || '').split(/\s+/)[0].toLowerCase();
    return ['claude', 'codex', 'gemini', 'cursor', 'you'].includes(w) ? 'agent-' + w : 'agent-other';
  }

  // "claude via T3 Code": the agent in its color, the rest quiet
  function agentName(a) {
    a = a || 'an agent';
    const m = /^(\S+)( via .+)$/.exec(a);
    if (m) return [h('span', { class: 'agent ' + agentClass(a), text: m[1] }), h('span', { class: 'via', text: m[2] })];
    return [h('span', { class: 'agent ' + agentClass(a), text: a })];
  }

  // the agents' own marks (the same ones the Mac app shows, from Simple Icons), one path each in a 24-unit box
  const LOGOS = {
    claude: 'm4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z',
    codex: 'M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z',
    gemini: 'M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81',
    cursor: 'M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23',
  };

  function avatar(a, cls) {
    const kind = agentClass(a);
    const el = h('span', { class: 'avatar ' + kind + (cls ? ' ' + cls : ''), 'aria-hidden': 'true' });
    const logo = LOGOS[kind.slice('agent-'.length)];
    if (logo) {
      const s = document.createElementNS(SVG, 'svg');
      s.setAttribute('viewBox', '0 0 24 24');
      s.setAttribute('class', 'logo');
      const p = document.createElementNS(SVG, 'path');
      p.setAttribute('d', logo);
      s.append(p);
      el.append(s);
    } else {
      el.textContent = unverified(a) ? '?' : (a || '?').trim().charAt(0).toUpperCase();
    }
    return el;
  }

  function tile(name) {
    const letter = (name || '?').replace(/^[^A-Za-z0-9]+/, '').charAt(0).toUpperCase() || '?';
    return h('span', { class: 'tile', 'aria-hidden': 'true', text: letter });
  }

  const who = () => (info && info.agent) || 'the agent';

  function appName(i) {
    if (i.app_name) return i.app_name;
    const parts = String(i.app).split('.');
    return parts[parts.length - 1];
  }

  function expiresText() {
    const s = Math.max(0, Math.round((deadline - Date.now()) / 1000));
    if (s >= 90) return 'expires in ' + Math.round(s / 60) + ' min';
    if (s > 0) return 'expires in ' + s + ' s';
    return 'expired';
  }

  function capitalized(s) {
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  // "let claude fill GitHub’s login in the browser" -> "Let claude fill GitHub’s login in the browser?", agent in color
  function question(i) {
    if (i.blanks && i.blanks.length) return [...agentName(i.agent || 'the agent'), ' needs you to finish a command'];
    let s = i.prompt;
    if (!s) {
      const action = i.action || 'use it';
      s = action.includes('its ') ? 'let ' + who() + ' ' + action.replace('its ', i.entry + '’s ') : 'let ' + who() + ' ' + action + ' for ' + i.entry;
    }
    s = capitalized(s.trim().replace(/[.!]$/, ''));
    if (!s.endsWith('?')) s += '?';
    const a = i.agent || '';
    const at = a ? s.indexOf(a) : -1;
    if (at < 0) return [s];
    return [s.slice(0, at), ...agentName(a), s.slice(at + a.length)];
  }

  // ---- api ----------------------------------------------------------------

  async function api(method, path, body) {
    const opts = { method, credentials: 'same-origin', cache: 'no-store', headers: { Accept: 'application/json' } };
    if (body !== undefined) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
    let res;
    try {
      res = await fetch(path, opts);
    } catch (e) {
      return { ok: false, status: 0, data: { error: 'offline' } };
    }
    let data = {};
    try {
      data = await res.json();
    } catch (e) {
      data = {};
    }
    return { ok: res.ok, status: res.status, data: data || {} };
  }

  const infoPath = () => '/api/r/' + encodeURIComponent(id);
  const actPath = (what) => '/api/r/' + encodeURIComponent(id) + '/' + what;

  function take(data) {
    info = data;
    deadline = Date.now() + Math.max(0, Number(data.expires_in) || 0) * 1000;
  }

  // a failed request that ends the page: which screen says why
  function endFor(r) {
    const e = r.data.error;
    if (r.status === 0) return done('offline');
    if (r.status === 423 || e === 'locked') return done('locked');
    if (r.status === 410 || e === 'expired') return done('expired');
    if (r.status === 404 || e === 'not_found') return done('notFound');
    if (e === 'this_mac' || (e === 'not_yours' && r.data.self)) return done('thisMac');
    if (r.status === 403 && e === 'not_yours') return done('notYours');
    return done('error', r.data.message);
  }

  // ---- flow ---------------------------------------------------------------

  async function load() {
    if (!id) return done('home');
    const r = await api('GET', infoPath());
    if (!r.ok) return endFor(r);
    take(r.data);
    route();
  }

  function route() {
    if (info.state !== 'pending') return done('answered');
    if (deadline <= Date.now()) return done('expired');
    if (info.kind === 'approve') return approveView();
    if (info.kind === 'save') return info.paired ? saveView() : pairView();
    return done('error', 'otto sent a request this page doesn’t know.');
  }

  // a Mac-side answer (or the clock) can end the request while the page is open
  async function poll() {
    if (!live || busy || document.hidden) return;
    const r = await api('GET', infoPath());
    if (!live || busy) return;
    if (r.ok) {
      take(r.data);
      if (info.state !== 'pending') done('answered');
      return;
    }
    if (r.status === 404 || r.status === 410 || r.status === 423 || r.status === 403) endFor(r);
  }

  function startLive() {
    live = true;
    if (!poller) poller = setInterval(poll, POLL_MS);
  }

  function stopLive() {
    live = false;
    if (poller) clearInterval(poller);
    poller = null;
  }

  setInterval(() => {
    if (!live) return;
    if (deadline <= Date.now() && !busy) return done('expired');
    for (const el of document.querySelectorAll('.expires')) el.textContent = expiresText();
  }, 1000);

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) poll();
  });

  // ---- pieces -------------------------------------------------------------

  function chip(name, text) {
    return h('span', { class: 'chip' }, icon(name), h('span', { text }));
  }

  function note(agent, text) {
    return h('div', { class: 'note' }, avatar(agent, 'small'), h('p', { class: 'bubble', text }));
  }

  function meta(...extra) {
    return h('p', { class: 'meta' }, h('span', { class: 'expires', text: expiresText() }), ...extra);
  }

  function button(text, kind, onclick, type) {
    return h('button', { class: 'btn ' + kind, type: type || 'button', onclick }, h('span', { class: 'label', text }));
  }

  function working(btn, on) {
    btn.disabled = on;
    btn.classList.toggle('busy', on);
  }

  function say(el, text) {
    el.textContent = text || '';
    el.hidden = !text;
  }

  // six boxes over one numeric field; the digits show as dots
  function pinBox(label, onFull) {
    const input = h('input', {
      class: 'pin-input',
      type: 'text',
      inputmode: 'numeric',
      pattern: '[0-9]*',
      autocomplete: 'one-time-code',
      autocorrect: 'off',
      autocapitalize: 'off',
      spellcheck: 'false',
      enterkeyhint: 'done',
      'aria-label': label,
    });
    const cells = Array.from({ length: 6 }, () => h('span', { class: 'pin-cell' }));
    const wrap = h('div', { class: 'pin' }, h('div', { class: 'pin-cells', 'aria-hidden': 'true' }, cells), input);
    const paint = () => {
      const n = input.value.length;
      const focused = document.activeElement === input;
      cells.forEach((c, k) => {
        c.classList.toggle('filled', k < n);
        c.classList.toggle('active', focused && k === Math.min(n, 5));
      });
    };
    input.addEventListener('input', () => {
      const digits = input.value.replace(/\D/g, '').slice(0, 6);
      if (digits !== input.value) input.value = digits;
      wrap.classList.remove('bad');
      paint();
      if (digits.length === 6 && onFull) onFull();
    });
    input.addEventListener('focus', paint);
    input.addEventListener('blur', paint);
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && onFull && input.value.length === 6) onFull();
    });
    return {
      el: wrap,
      get value() {
        return input.value;
      },
      wrong() {
        wrap.classList.remove('bad');
        void wrap.offsetWidth; // restart the shake
        wrap.classList.add('bad');
        input.value = '';
        paint();
      },
      focus() {
        input.focus();
      },
    };
  }

  // what a wrong PIN, a lockout or a lost pairing means for the request on screen
  function pinTrouble(r, pin, err) {
    const e = r.data.error;
    if (e === 'wrong_pin') {
      pin.wrong();
      const left = Number(r.data.left);
      if (left === 1) say(err, 'wrong PIN. one more wrong one turns remote off.');
      else if (left > 1) say(err, 'wrong PIN. ' + left + ' tries left.');
      else say(err, 'wrong PIN.');
      pin.focus();
      return;
    }
    if (r.status === 409 || e === 'answered') return load();
    if (r.status === 400) return say(err, r.data.message || 'otto didn’t take that.');
    if (r.status === 0) return say(err, 'can’t reach otto right now. check that Tailscale is on, then try again.');
    endFor(r);
  }

  // ---- screens ------------------------------------------------------------

  function saveHead(i) {
    const needs = i.needs || [];
    const needsPassword = needs.length === 0 || needs.includes('password');
    const needsTOTP = needs.includes('totp') || needs.includes('2fa');
    const where = i.site || (i.app ? 'the ' + appName(i) + ' app' : 'new entry');
    return h(
      'section',
      { class: 'head' },
      h('div', { class: 'head-row' }, tile(i.name), h('div', { class: 'head-text' }, h('h1', {}, agentName(i.agent), ' needs your ' + i.name + ' login'), h('p', { class: 'where', text: where }))),
      h('div', { class: 'chips' }, needsPassword && chip('key', 'password'), needsTOTP && chip('hash', '2FA code')),
      i.note && note(i.agent, i.note),
    );
  }

  function pairView() {
    const err = h('p', { class: 'error', role: 'alert', hidden: true });
    const go = async () => {
      if (busy) return;
      if (pin.value.length !== 6) return say(err, 'the PIN has 6 digits.');
      busy = true;
      working(btn, true);
      say(err, '');
      const r = await api('POST', '/api/pair', { pin: pin.value });
      busy = false;
      working(btn, false);
      if (r.ok) {
        info.paired = true;
        if (r.data.device) info.device = r.data.device;
        return route();
      }
      pinTrouble(r, pin, err);
    };
    const pin = pinBox('otto PIN', go);
    const btn = button('Pair this phone', 'primary', go);
    show(
      'pair',
      saveHead(info),
      h(
        'section',
        { class: 'card pair' },
        h('div', { class: 'pair-title' }, icon('phone'), h('h2', { text: 'pair this phone' })),
        h('p', { class: 'hint', text: 'enter the PIN you set in otto on your Mac. you only do this once on this phone.' }),
        pin.el,
        err,
        btn,
        info.device && h('p', { class: 'fine', text: 'it shows up in otto as ' + info.device + '.' }),
      ),
      meta(),
    );
    startLive();
  }

  function saveView() {
    const i = info;
    const needs = i.needs || [];
    const needsPassword = needs.length === 0 || needs.includes('password');
    const needsTOTP = needs.includes('totp') || needs.includes('2fa');
    const ex = i.existing || null;
    let twoFactor = 'app';

    const user = h('input', {
      class: 'input',
      type: 'text',
      name: 'username',
      autocomplete: 'username',
      autocapitalize: 'none',
      autocorrect: 'off',
      spellcheck: 'false',
      placeholder: 'email or username',
      id: 'f-user',
    });
    user.value = i.username || (ex && ex.username) || '';
    const pw = h('input', {
      class: 'input',
      type: 'password',
      name: 'password',
      autocomplete: 'current-password',
      autocapitalize: 'none',
      autocorrect: 'off',
      spellcheck: 'false',
      placeholder: ex && ex.has_password ? 'unchanged' : 'password',
      id: 'f-pass',
    });
    const reveal = h('button', { class: 'reveal', type: 'button', 'aria-label': 'show password', 'aria-pressed': 'false' }, icon('eye'));
    reveal.addEventListener('click', (e) => {
      e.preventDefault();
      const showing = pw.type === 'text';
      pw.type = showing ? 'password' : 'text';
      pw.classList.toggle('mono', !showing);
      reveal.replaceChildren(icon(showing ? 'eye' : 'eyeoff'));
      reveal.setAttribute('aria-pressed', String(!showing));
      reveal.setAttribute('aria-label', showing ? 'show password' : 'hide password');
    });

    const otp = h('input', {
      class: 'input mono-ish',
      type: 'text',
      name: 'otp',
      autocomplete: 'off',
      autocapitalize: 'none',
      autocorrect: 'off',
      spellcheck: 'false',
      placeholder: ex && ex.has_2fa ? 'unchanged' : 'setup key or otpauth:// link',
      id: 'f-otp',
      'aria-label': '2FA setup key',
    });
    const otpErr = h('p', { class: 'error', role: 'alert', hidden: true });
    const err = h('p', { class: 'error', role: 'alert', hidden: true });

    const ready = () =>
      (!needsPassword || pw.value.length > 0 || (ex && ex.has_password)) &&
      (!needsTOTP || twoFactor !== 'app' || otp.value.trim().length > 0 || (ex && ex.has_2fa));

    const save = button('Save', 'primary', null, 'submit');
    const later = button('Not now', 'soft', async () => {
      if (busy) return;
      busy = true;
      working(later, true);
      const r = await api('POST', actPath('decline'), {});
      busy = false;
      working(later, false);
      if (r.ok) return done('declined', null, true);
      if (r.status === 401 || r.data.error === 'not_paired') return lostPairing();
      if (r.status === 409) return load();
      if (r.status === 0) return say(err, 'can’t reach otto right now. check that Tailscale is on, then try again.');
      endFor(r);
    });
    const refresh = () => {
      save.disabled = !ready();
    };

    // 2FA: where the code comes from, and what goes with each
    let twoFA = null;
    if (needsTOTP) {
      const choices = [
        ['app', 'Authenticator'],
        ['delivered', 'SMS or email'],
        ['none', 'No 2FA'],
      ];
      const hint = h('p', { class: 'hint small' });
      const otpRow = h('div', { class: 'otp-row' }, otp);
      const seg = h('div', { class: 'seg', role: 'radiogroup', 'aria-label': 'how the site does 2FA' });
      const paint = () => {
        for (const b of seg.children) b.setAttribute('aria-checked', String(b.dataset.v === twoFactor));
        otpRow.hidden = twoFactor !== 'app';
        hint.replaceChildren();
        if (twoFactor === 'app') hint.append('the key the site shows next to its 2FA QR code, often under “can’t scan it?”.');
        if (twoFactor === 'delivered') hint.append('when the site sends you a code, ', ...agentName(i.agent), ' will ask you for it.');
        if (twoFactor === 'none') hint.append('no second step. the password is enough.');
        say(otpErr, '');
        refresh();
      };
      for (const [v, label] of choices) {
        const b = h('button', { type: 'button', role: 'radio', class: 'seg-item', 'data-v': v, text: label });
        b.addEventListener('click', () => {
          twoFactor = v;
          paint();
          if (v === 'app') otp.focus();
        });
        seg.append(b);
      }
      twoFA = h('section', { class: 'group' }, h('h3', { class: 'group-title', text: '2FA' }), h('div', { class: 'card pad' }, seg, otpRow, otpErr, hint));
      paint();
    }

    for (const el of [user, pw, otp]) el.addEventListener('input', refresh);

    const form = h(
      'form',
      { class: 'form', novalidate: true, autocomplete: 'on' },
      needsPassword &&
        h(
          'section',
          { class: 'group' },
          h(
            'div',
            { class: 'card rows' },
            h('label', { class: 'row', for: 'f-user' }, h('span', { class: 'row-label', text: 'Username' }), user),
            h('label', { class: 'row', for: 'f-pass' }, h('span', { class: 'row-label', text: 'Password' }), pw, reveal),
          ),
        ),
      twoFA,
      h('p', { class: 'promise' }, icon('eyeoff'), h('span', {}, agentName(i.agent), ' never sees these' + (i.site ? ' and can only use them on ' + i.site : '') + '.')),
      err,
      h('div', { class: 'actions' }, save, later),
    );
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      if (busy || !ready()) return;
      busy = true;
      working(save, true);
      say(err, '');
      say(otpErr, '');
      const body = {
        username: needsPassword ? user.value.trim() : null,
        password: needsPassword ? pw.value : null,
        two_factor: needsTOTP ? twoFactor : null,
        otp: needsTOTP && twoFactor === 'app' ? otp.value.trim() : null,
      };
      const r = await api('POST', actPath('save'), body);
      busy = false;
      working(save, false);
      refresh();
      if (r.ok) return done('saved', null, true);
      if (r.status === 401 || r.data.error === 'not_paired') return lostPairing();
      if (r.status === 409) return load();
      if (r.status === 400) {
        const where = /totp|otp|2fa/i.test(r.data.error || '') && needsTOTP ? otpErr : err;
        return say(where, r.data.message || 'otto didn’t take that.');
      }
      if (r.status === 0) return say(err, 'can’t reach otto right now. check that Tailscale is on, then try again.');
      endFor(r);
    });

    refresh();
    show('save', saveHead(i), form, meta());
    startLive();
  }

  // the phone's pairing is gone (removed in otto on the Mac): pair again, keep the request
  function lostPairing() {
    info.paired = false;
    if (info.kind === 'save') {
      pairView();
      const err = app.querySelector('.pair .error');
      if (err) say(err, 'this phone isn’t paired anymore. enter your PIN to pair it again.');
      return;
    }
    approveView('this phone isn’t paired anymore. your PIN pairs it again.');
  }

  // what a change would write, hidden behind the eye (a username shows as it is)
  function changeRow(c) {
    const what = 'new ' + c.field;
    if (c.value == null) {
      return h('div', { class: 'row change' }, h('span', { class: 'row-icon' }, icon('key')), h('div', { class: 'row-text' }, h('span', { class: 'row-sub', text: what }), h('span', { class: 'row-main', text: c.label || 'a new value' })));
    }
    const dots = '••••••••••••';
    const val = h('span', { class: 'row-main change-value' + (c.secret ? '' : ' mono'), text: c.secret ? dots : c.value });
    const kids = [h('span', { class: 'row-icon' }, icon('key')), h('div', { class: 'row-text grow' }, h('span', { class: 'row-sub', text: what }), val)];
    if (c.secret) {
      const reveal = h('button', { class: 'reveal', type: 'button', 'aria-label': 'show it', 'aria-pressed': 'false' }, icon('eye'));
      reveal.addEventListener('click', (e) => {
        e.preventDefault();
        const showing = reveal.getAttribute('aria-pressed') === 'true';
        val.textContent = showing ? dots : c.value;
        val.classList.toggle('mono', !showing);
        reveal.replaceChildren(icon(showing ? 'eye' : 'eyeoff'));
        reveal.setAttribute('aria-pressed', String(!showing));
        reveal.setAttribute('aria-label', showing ? 'show it' : 'hide it');
      });
      kids.push(reveal);
    }
    return h('div', { class: 'row change' }, ...kids);
  }

  // what's been typed into a command's blanks and whether to keep it, by name (a lost pairing redraws the page)
  const typed = {};
  const keeping = {};
  const reusing = {};

  function blankField(b, onInput) {
    const fieldId = 'blank-' + Object.keys(typed).length;
    typed[b.name] = typed[b.name] || b.value || '';
    if (!(b.name in keeping)) keeping[b.name] = !!b.saved;
    const input = h('input', {
      class: 'input mono',
      type: b.secret ? 'password' : 'text',
      autocomplete: 'off',
      autocapitalize: 'none',
      autocorrect: 'off',
      spellcheck: 'false',
      id: fieldId,
      'aria-label': b.name,
      // a secret stays in the vault: the page only knows it's there
      placeholder: b.saved && !b.value ? 'saved' : null,
    });
    input.value = typed[b.name];
    input.addEventListener('input', () => {
      typed[b.name] = input.value;
      onInput();
    });
    const kids = [input];
    if (b.secret) {
      const reveal = h('button', { class: 'reveal', type: 'button', 'aria-label': 'show ' + b.name, 'aria-pressed': 'false' }, icon('eye'));
      reveal.addEventListener('click', (e) => {
        e.preventDefault();
        const showing = input.type === 'text';
        input.type = showing ? 'password' : 'text';
        reveal.replaceChildren(icon(showing ? 'eye' : 'eyeoff'));
        reveal.setAttribute('aria-pressed', String(!showing));
        reveal.setAttribute('aria-label', (showing ? 'show ' : 'hide ') + b.name);
        onInput();
      });
      kids.push(reveal);
    }
    const keep = h('input', { type: 'checkbox', 'aria-label': 'remember ' + b.name });
    keep.checked = keeping[b.name];
    keep.addEventListener('change', () => {
      keeping[b.name] = keep.checked;
    });
    const row = h(
      'div',
      { class: 'blank-field' },
      h('div', { class: 'blank-top' }, h('label', { class: 'row-sub', for: fieldId, text: b.name }), h('label', { class: 'blank-keep' }, keep, h('span', { text: 'remember' }))),
      h('span', { class: 'blank-input' }, ...kids),
    );
    // a secret saved for other commands: otto only uses it here if the user says so
    let reuse = null;
    if (b.elsewhere) {
      reuse = h('input', { type: 'checkbox', 'aria-label': 'use the ' + b.name + ' you saved' });
      reuse.checked = !!reusing[b.name];
      const apply = () => {
        reusing[b.name] = reuse.checked;
        input.disabled = reuse.checked;
        input.placeholder = reuse.checked ? 'saved' : '';
        if (reuse.checked) input.value = typed[b.name] = '';
      };
      apply();
      reuse.addEventListener('change', () => {
        apply();
        onInput();
      });
      const where = b.elsewhere.length ? 'it’s saved for ' + b.elsewhere[0] + (b.elsewhere.length > 1 ? ' and ' + (b.elsewhere.length - 1) + ' more' : '') + '.' : 'you haven’t used it in a command yet.';
      row.append(
        h('label', { class: 'blank-keep blank-reuse' }, reuse, h('span', { text: 'use the “' + b.name + '” you saved' })),
        h('p', { class: 'hint small', text: where + ' otto won’t use it here unless you tick this.' }),
      );
    }
    return { input, keep, reuse, blank: b, row };
  }

  // the command as it stands: what's filled in shows (a secret as dots), what isn't stands out
  function paintCommand(el, command, blanks, fields) {
    const parts = [];
    let rest = command;
    while (rest) {
      let next = null;
      blanks.forEach((b, n) => {
        const at = rest.indexOf('{{' + b.name + '}}');
        if (at >= 0 && (!next || at < next.at)) next = { at, b, n };
      });
      if (!next) break;
      if (next.at) parts.push(rest.slice(0, next.at));
      const value = typed[next.b.name] || '';
      const visible = !next.b.secret || (fields[next.n] && fields[next.n].input.type === 'text');
      if (value) parts.push(visible ? value : '•'.repeat(Math.min(value.length, 12)));
      else parts.push(next.b.saved || reusing[next.b.name] ? '•'.repeat(12) : h('span', { class: 'blank-mark', text: next.b.name }));
      rest = rest.slice(next.at + next.b.name.length + 4);
    }
    if (rest) parts.push(rest);
    el.replaceChildren(...parts);
  }

  function approveView(problem) {
    const i = info;
    const err = h('p', { class: 'error', role: 'alert', hidden: true });
    const pin = pinBox('otto PIN');
    const blanks = i.blanks || [];
    const commandText = h('span', { class: 'row-main change-value mono command' });
    const fields = [];
    const repaint = () => paintCommand(commandText, i.command || '', blanks, fields);
    for (const b of blanks) {
      fields.push(
        blankField(b, () => {
          say(err, '');
          repaint();
        }),
      );
    }
    const missing = () => fields.find((f) => !f.blank.saved && !(f.reuse && f.reuse.checked) && !f.input.value.trim());
    const allow = button('Allow', 'primary', null, 'submit');
    const deny = button('Don’t allow', 'soft', async () => {
      if (busy) return;
      if (!info.paired && pin.value.length !== 6) {
        pin.focus();
        return say(err, 'enter your PIN first. or leave it: the request runs out by itself.');
      }
      busy = true;
      working(deny, true);
      say(err, '');
      if (!info.paired) {
        const p = await api('POST', '/api/pair', { pin: pin.value });
        if (!p.ok) {
          busy = false;
          working(deny, false);
          return pinTrouble(p, pin, err);
        }
        info.paired = true;
      }
      const r = await api('POST', actPath('decline'), {});
      busy = false;
      working(deny, false);
      if (r.ok) return done('declined', null, true);
      if (r.status === 401 || r.data.error === 'not_paired') return lostPairing();
      pinTrouble(r, pin, err);
    });

    const form = h('form', { class: 'form', novalidate: true });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      if (busy) return;
      const empty = missing();
      if (empty) {
        empty.input.focus();
        return say(err, 'fill in ' + empty.input.getAttribute('aria-label') + ' first.');
      }
      if (pin.value.length !== 6) {
        pin.focus();
        return say(err, 'enter your 6-digit otto PIN.');
      }
      busy = true;
      working(allow, true);
      say(err, '');
      // first time on this phone: the same PIN pairs it, then allows
      if (!info.paired) {
        const p = await api('POST', '/api/pair', { pin: pin.value });
        if (!p.ok) {
          busy = false;
          working(allow, false);
          return pinTrouble(p, pin, err);
        }
        info.paired = true;
        if (p.data.device) info.device = p.data.device;
      }
      const r = await api('POST', actPath('approve'), blanks.length ? { pin: pin.value, values: fields.map((f) => f.input.value), remember: fields.map((f) => f.keep.checked), ...(fields.some((f) => f.reuse) ? { reuse: fields.map((f) => !!(f.reuse && f.reuse.checked)) } : {}) } : { pin: pin.value });
      busy = false;
      working(allow, false);
      if (r.ok) return done('approved', null, true);
      if (r.status === 401 || r.data.error === 'not_paired') return lostPairing();
      if (r.data.error === 'blank') return say(err, r.data.message);
      pinTrouble(r, pin, err);
    });

    const kinds = { login: 'login', card: 'card', key: 'API key', note: 'secure note', mac: 'Mac password' };
    const sub = i.sites && i.sites.length ? i.sites.join(', ') : kinds[i.entry_kind] || 'login';
    // a command (otto approve, run_command): the command itself, as it will run, and the agent's reason
    const what = i.command
      ? [
          h('div', { class: 'row' }, h('span', { class: 'row-icon' }, icon('terminal')), h('div', { class: 'row-text grow' }, h('span', { class: 'row-sub', text: 'runs once, as you' }), commandText)),
          i.why && h('div', { class: 'row' }, h('span', { class: 'row-icon' }, icon('message')), h('div', { class: 'row-text' }, h('span', { class: 'row-sub', text: 'why, in ' + (i.agent || 'the agent') + '’s words' }), h('span', { class: 'row-main', text: i.why }))),
        ]
      : [h('div', { class: 'row' }, tile(i.entry), h('div', { class: 'row-text' }, h('span', { class: 'row-main', text: i.entry }), h('span', { class: 'row-sub', text: sub })))];
    form.append(
      ...[
        h(
          'section',
          { class: 'card rows details' },
          ...what.filter(Boolean),
          i.change && changeRow(i.change),
          i.folder && h('div', { class: 'row' }, h('span', { class: 'row-icon' }, icon('folder')), h('div', { class: 'row-text' }, h('span', { class: 'row-main', text: 'in ' + i.folder }), h('span', { class: 'row-sub', text: i.command ? 'where it runs' : 'where ' + (i.agent || 'the agent') + ' is working' }))),
        ),
        unverified(i.agent) && h('p', { class: 'warn' }, icon('alert'), h('span', { text: 'otto couldn’t check who this is by its signature. only allow it if you started it yourself.' })),
        blanks.length > 0 && h('section', { class: 'group' }, h('h3', { class: 'group-title', text: 'Fill in' }), h('div', { class: 'card blanks' }, ...fields.map((f) => f.row)), h('p', { class: 'hint small', text: 'what you remember stays in your vault. a secret only comes back for this exact command.' })),
        blanks.length > 0 && h('p', { class: 'promise' }, icon('eyeoff'), h('span', {}, agentName(i.agent), ' gets the command’s output, with what you typed hidden.')),
        h(
          'section',
          { class: 'card pad pinpad' },
          h('p', { class: 'hint center', text: info.paired ? 'your otto PIN, to allow it' : 'your otto PIN. the first time, it also pairs this phone.' }),
          pin.el,
          err,
        ),
        h('div', { class: 'actions' }, allow, deny),
      ].filter(Boolean),
    );

    show(
      'approve',
      h('section', { class: 'head ask' }, avatar(i.agent, 'big'), h('h1', {}, question(i))),
      form,
      meta(),
    );
    repaint();
    if (problem) say(err, problem);
    startLive();
  }

  // the end of a request, or a page with nothing to do
  function done(kind, message, mine) {
    stopLive();
    const i = info || {};
    const name = i.name || i.entry || 'it';
    const agent = i.agent || 'the agent';
    const from = i.answered_from;
    let ic = 'alert';
    let tone = '';
    let title = '';
    let body = [];
    let action = null;
    switch (kind) {
      case 'home':
        ic = 'tray';
        title = 'nothing waiting';
        body = ['when an agent sends you a link, it opens here.'];
        break;
      case 'saved':
        ic = 'check';
        tone = 'good';
        title = 'saved';
        body = [...agentName(agent), ' can use your ' + name + ' login now. you can close this page.'];
        break;
      case 'approved':
        ic = 'check';
        tone = 'good';
        title = 'allowed';
        body = [...agentName(agent), ' can go ahead. you can close this page.'];
        break;
      case 'declined':
        ic = 'x';
        title = 'you said no';
        body = ['otto told ', ...agentName(agent), '. you can close this page.'];
        break;
      case 'answered': {
        if (i.state === 'expired') return done('expired');
        ic = i.state === 'declined' ? 'x' : 'check';
        title = { saved: 'already saved', approved: 'already allowed', declined: 'already turned down' }[i.state] || 'already answered';
        const where = !from ? 'somewhere else' : from === 'the Mac' ? 'at the Mac' : 'on ' + from;
        body = ['you answered ' + where + '.'];
        break;
      }
      case 'expired':
        ic = 'clock';
        title = 'this link expired';
        body = ['ask ', ...agentName(agent), ' for a new one if it still needs it.'];
        break;
      case 'notFound':
        ic = 'x';
        title = 'this link doesn’t work';
        body = ['it was already used, or otto restarted since. ask the agent for a new one.'];
        break;
      case 'notYours':
        ic = 'lock';
        title = 'not on this device';
        body = ['this only opens on your own devices on Tailscale.'];
        break;
      case 'thisMac':
        ic = 'phone';
        title = 'open it on your phone';
        body = ['on the Mac, click otto’s notification to answer there. this link is for your other devices.'];
        break;
      case 'locked':
        ic = 'lock';
        title = 'remote is off';
        body = ['after too many wrong PINs. set the PIN again in otto on your Mac to turn it back on.'];
        break;
      case 'offline':
        ic = 'cloud';
        title = 'can’t reach otto';
        body = ['check that Tailscale is on, here and on your Mac, and that otto is open.'];
        action = button('Try again', 'soft', () => {
          show('loading', h('div', { class: 'loading', role: 'status' }, h('span', { class: 'spinner', 'aria-hidden': 'true' })));
          load();
        });
        break;
      default:
        title = 'something went wrong';
        body = [message || 'otto couldn’t open this request.'];
        action = button('Try again', 'soft', () => load());
    }
    show(
      'done',
      h(
        'section',
        { class: 'status ' + (tone || 'plain') + (mine ? ' fresh' : '') },
        h('span', { class: 'status-icon' }, icon(ic)),
        h('h1', { text: title }),
        h('p', { class: 'status-body' }, body),
        action,
      ),
    );
  }

  load();
})();
