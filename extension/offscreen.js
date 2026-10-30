// The service worker can't see light or dark mode (it has no matchMedia), so this hidden page watches it
// and tells the worker, which colors the toolbar icon to match. A page that's never drawn doesn't get
// matchMedia's change event, but `matches` stays current, so it's read every couple of seconds.
const dark = matchMedia('(prefers-color-scheme: dark)');
let told = dark.matches;
const tell = (changed) => chrome.runtime.sendMessage({ type: 'scheme', dark: (told = dark.matches), changed }).catch(() => {});
setInterval(() => dark.matches !== told && tell(true), 2000);
// a worker that just started, or that saw Chrome come to the front, asks
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.type === 'scheme?') reply({ dark: dark.matches });
});
tell(false);
