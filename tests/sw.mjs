// evaluate JS inside the otto extension's service worker: node sw.mjs <port> <js>
const [port, js] = process.argv.slice(2);
const t = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'service_worker' && t.url.includes('background.js'));
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise((ok) => (ws.onopen = ok));
const r = await new Promise((ok) => {
  ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id === 1) ok(m); };
  ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: js, returnByValue: true, awaitPromise: true } }));
});
ws.close();
console.log(JSON.stringify(r.result?.result?.value ?? r));
