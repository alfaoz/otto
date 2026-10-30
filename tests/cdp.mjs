// tiny Chrome DevTools Protocol driver for tests. node cdp.mjs <port> <cmd> [args]
//   open <url> | list | goto <match> <url> | eval <match> <js> | text <match> | close <match>
const [port, cmd, ...args] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
const targets = async () => (await (await fetch(`${base}/json/list`)).json()).filter((t) => t.type === 'page');
const find = async (m) => {
  const t = (await targets()).find((t) => t.url.includes(m));
  if (!t) throw new Error(`no tab matching ${m}`);
  return t;
};
async function send(t, method, params = {}) {
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((ok, no) => { ws.onopen = ok; ws.onerror = no; });
  const r = await new Promise((ok) => {
    ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id === 1) ok(m); };
    ws.send(JSON.stringify({ id: 1, method, params }));
  });
  ws.close();
  if (r.error) throw new Error(JSON.stringify(r.error));
  return r.result;
}
const evalIn = async (m, js) => (await send(await find(m), 'Runtime.evaluate', { expression: js, returnByValue: true, awaitPromise: true })).result.value;
switch (cmd) {
  case 'open': console.log((await (await fetch(`${base}/json/new?${args[0]}`, { method: 'PUT' })).json()).url); break;
  case 'list': for (const t of await targets()) console.log(t.url); break;
  case 'goto': await send(await find(args[0]), 'Page.navigate', { url: args[1] }); console.log('ok'); break;
  case 'eval': console.log(JSON.stringify(await evalIn(args[0], args[1]))); break;
  case 'text': console.log(await evalIn(args[0], 'document.body.innerText')); break;
  case 'close': await fetch(`${base}/json/close/${(await find(args[0])).id}`); console.log('closed'); break;
}
