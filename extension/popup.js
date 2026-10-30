// The toolbar popup: where otto is at, as the worker (background.js) knows it, and a way to open the app.

const $ = (id) => document.getElementById(id);

// per state: the dot's tone, the line beside it, what to say, and whether to offer opening the app
// (`soft` when it's there just to get to the app, not to fix anything)
const VIEWS = {
  checking: { tone: '', title: 'checking…' },
  connected: {
    tone: 'good',
    title: 'connected',
    text: (s) => `agents can fill logins and 2FA codes in ${s.browser || 'this browser'}.`,
    open: 'soft',
  },
  not_running: {
    tone: 'bad',
    title: 'the otto app isn\'t running',
    text: () => 'agents can\'t log in or get 2FA codes until it\'s open.',
    open: 'primary',
  },
  locked: {
    tone: 'warn',
    title: 'locked',
    text: () => 'open the otto app to unlock the vault.',
    open: 'primary',
  },
  refused: {
    tone: 'bad',
    title: 'otto doesn\'t trust this browser',
    text: (s) => s.detail || 'open the otto app to see which browsers it trusts.',
    open: 'soft',
  },
  relaunch: {
    tone: 'warn',
    title: 'relaunch this browser',
    text: (s) => s.detail,
  },
  // the helper is what opens the app, so there's no button here
  no_helper: {
    tone: 'bad',
    title: 'Chrome can\'t reach otto',
    text: () => 'open the otto app once: it sets up the helper Chrome talks to.',
    note: (s) => s.detail,
  },
};

// how long "opening…" waits for the app before offering the button again
const OPEN_WAIT_MS = 15000;
let status = { state: 'checking' };
let opening = null;

function render() {
  const v = VIEWS[status.state] || VIEWS.checking;
  if (opening && status.state === 'connected') {
    clearTimeout(opening);
    opening = null;
  }
  $('state').className = `state ${v.tone}`;
  $('title').textContent = v.title;
  const text = v.text?.(status);
  $('text').hidden = !text;
  $('text').textContent = text || '';
  const note = v.note?.(status);
  $('note').hidden = !note;
  $('note').textContent = note || '';
  const b = $('open');
  b.hidden = !v.open;
  b.className = v.open === 'soft' ? 'soft' : '';
  b.disabled = !!opening;
  b.textContent = opening ? 'opening…' : 'Open otto';
}

$('open').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'open_app' }).catch(() => {});
  // once it's up there's nothing to wait for, so the popup's job is done
  if (status.state === 'connected') return window.close();
  opening = setTimeout(() => {
    opening = null;
    render();
  }, OPEN_WAIT_MS);
  render();
});

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (msg?.type !== 'status' || sender.id !== chrome.runtime.id) return;
  status = msg.status;
  render();
});

chrome.runtime.sendMessage({ type: 'status?' }).then((s) => {
  if (s) status = s;
  render();
}, render);
