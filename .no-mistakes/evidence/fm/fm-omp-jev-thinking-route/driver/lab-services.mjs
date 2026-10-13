// Disposable lab services for the omp direct-judge live validation.
// - fixture: a scripted OpenAI-compatible primary model ("fixture/main") and a
//   "secondary/tiny" trap, on plain loopback HTTP.
// - proxy: an HTTPS_PROXY that intercepts api.typesafe.ai and openrouter.ai with
//   a lab-only CA (fake TypeSafe answers, OpenRouter always a 503 trap) and
//   refuses every other host, so no lab request leaves this machine.
// Every request is appended to <work>/requests.jsonl with the current phase
// (read from <work>/phase) and a credential label, never a credential value.
import { createServer } from 'node:http';
import { createServer as createNet } from 'node:net';
import { TLSSocket, createSecureContext } from 'node:tls';
import { appendFileSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const work = process.argv[2];
const log = join(work, 'requests.jsonl');
const KNOWN = {
  'Bearer fake-lab-typesafe-primary': 'lab-typesafe-key',
  'Bearer fake-lab-openrouter-trap': 'lab-openrouter-key',
  'Bearer fake-lab-main': 'lab-main-key',
  'Bearer fake-lab-secondary': 'lab-secondary-key',
};
const phase = () => { try { return readFileSync(join(work, 'phase'), 'utf8').trim(); } catch { return 'none'; } };
const mode = () => { try { return readFileSync(join(work, 'typesafe-mode'), 'utf8').trim(); } catch { return 'healthy'; } };
const credential = (req) => {
  const raw = req.headers.authorization ?? (req.headers['x-api-key'] ? `Bearer ${req.headers['x-api-key']}` : undefined);
  if (!raw) return 'none';
  return KNOWN[raw] ?? 'unknown-credential';
};
const record = (row) => appendFileSync(log, JSON.stringify({ at: new Date().toISOString(), phase: phase(), ...row }) + '\n');
const body = (req) => new Promise((resolve) => { let b = ''; req.on('data', (c) => { b += c; }); req.on('end', () => resolve(b)); });

function chooseTool(names, toolResults) {
  const plan = ['find', 'bash', 'read'];
  const available = plan.map((want) => names.find((n) => n === want || n?.endsWith(`_${want}`))).filter(Boolean);
  return available[toolResults];
}
const ARGS = {
  find: { query: 'Adding two numbers', grep_keywords: ['add'], path: '.' },
  bash: { command: 'echo lab-bash-probe' },
  read: { path: 'counter.ts' },
};

let completion = 0;
const fixture = createServer(async (req, res) => {
  const text = await body(req);
  const payload = text ? JSON.parse(text) : {};
  const names = payload.tools?.map((t) => t.function?.name) ?? [];
  const toolResults = (payload.messages ?? []).filter((m) => m.role === 'tool').length;
  const row = { service: req.url.startsWith('/secondary') ? 'secondary' : 'fixture', method: req.method, path: req.url, model: payload.model, credential: credential(req), toolsOffered: names };
  if (req.url.startsWith('/secondary')) {
    record(row);
    res.writeHead(503, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: 'secondary model trap contacted' })); return;
  }
  if (req.method === 'GET') { record(row); res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ data: [{ id: 'main', object: 'model' }] })); return; }
  if (!req.url.endsWith('/chat/completions')) { record(row); res.writeHead(404); res.end('{}'); return; }
  completion++;
  const tool = chooseTool(names, toolResults);
  const short = tool && (['find', 'bash', 'read'].find((w) => tool === w || tool.endsWith(`_${w}`)));
  record({ ...row, toolResultsSoFar: toolResults, reply: tool ? `tool:${tool}` : 'text' });
  res.setHeader('content-type', 'text/event-stream');
  const emit = (choice) => res.write(`data: ${JSON.stringify({ id: `fixture-${completion}`, object: 'chat.completion.chunk', created: 1, model: 'main', choices: [choice] })}\n\n`);
  if (tool) {
    emit({ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: `fixture-call-${completion}`, type: 'function', function: { name: tool, arguments: JSON.stringify(ARGS[short]) } }] }, finish_reason: null });
    emit({ index: 0, delta: {}, finish_reason: 'tool_calls' });
  } else {
    emit({ index: 0, delta: { role: 'assistant', content: 'Lab fixture finished: counter.ts adds two numbers.' }, finish_reason: null });
    emit({ index: 0, delta: {}, finish_reason: 'stop' });
  }
  res.write('data: [DONE]\n\n'); res.end();
});

const intercepted = createServer(async (req, res) => {
  const host = req.socket.servername ?? req.headers.host;
  const text = await body(req);
  let payload = {};
  try { payload = text ? JSON.parse(text) : {}; } catch { payload = {}; }
  const row = { service: host, method: req.method, path: req.url, model: payload.model, credential: credential(req) };
  if (host === 'openrouter.ai') {
    record(row);
    res.writeHead(503, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: 'OpenRouter trap contacted' })); return;
  }
  // api.typesafe.ai
  if (req.method === 'GET') { record(row); res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ data: [] })); return; }
  if (req.url.endsWith('/v1/systemone')) {
    const types = Object.values(payload.questions ?? {}).map((q) => q.type);
    record({ ...row, questionTypes: types, typesafeMode: mode() });
    if (mode() === 'unavailable') { res.writeHead(503, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: 'TypeSafe deliberately unavailable' })); return; }
    const answers = Object.fromEntries(Object.entries(payload.questions ?? {}).map(([id, q]) => {
      if (q.type === 'noul') return [id, { type: 'noul', noul: 0.05 }];
      if (q.type === 'choice') { const keys = Object.keys(q.criteria ?? {}); return [id, { type: 'choice', choice: keys[0], confidence: 1, probabilities: Object.fromEntries(keys.map((k, i) => [k, +(i === 0)])) }]; }
      return [id, { type: q.type }];
    }));
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ model: 'jev-lab-fake', answers, usage: { input_tokens: 3, output_tokens: 1, cost: 0 } }));
    return;
  }
  record(row);
  res.writeHead(404, { 'content-type': 'application/json' }); res.end('{}');
});

const contexts = Object.fromEntries(['api.typesafe.ai', 'openrouter.ai'].map((h) => [h, createSecureContext({ key: readFileSync(join(work, 'certs', `${h}.key`)), cert: readFileSync(join(work, 'certs', `${h}.crt`)) })]));
const proxy = createNet((socket) => {
  socket.once('data', (head) => {
    const line = head.toString('latin1').split('\r\n')[0];
    const m = /^CONNECT ([^:\s]+):(\d+) HTTP/.exec(line);
    if (!m) {
      const target = line.split(' ')[1];
      record({ service: 'proxy-refused', method: line.split(' ')[0], path: target });
      socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'); return;
    }
    const host = m[1];
    if (!contexts[host]) {
      record({ service: 'proxy-refused', method: 'CONNECT', path: `${host}:${m[2]}` });
      socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'); return;
    }
    socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    const tls = new TLSSocket(socket, { isServer: true, secureContext: contexts[host], ALPNProtocols: ['http/1.1'] });
    tls.servername = host;
    tls.on('error', (e) => record({ service: 'tls-error', path: host, error: String(e.message) }));
    intercepted.emit('connection', tls);
  });
  socket.on('error', () => {});
});

await new Promise((r) => fixture.listen(0, '127.0.0.1', r));
await new Promise((r) => proxy.listen(0, '127.0.0.1', r));
writeFileSync(join(work, 'ports.json'), JSON.stringify({ fixture: fixture.address().port, proxy: proxy.address().port }));
console.log(`lab services ready fixture=${fixture.address().port} proxy=${proxy.address().port}`);
const stop = () => { fixture.close(); proxy.close(); process.exit(0); };
process.on('SIGTERM', stop); process.on('SIGINT', stop);
