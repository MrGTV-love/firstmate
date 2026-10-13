// Loopback stand-ins: fixture main model (OpenAI chat), TypeSafe systemone (native + guard),
// OpenRouter and secondary traps. Every request is appended to requests.jsonl.
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
const [log, portFile] = process.argv.slice(2);
let scenario = 'idle', tool = 'none', typesafe = 'ok', completion = 0;
const server = createServer((req, res) => {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    if (req.url === '/__scenario') { ({ scenario, tool, typesafe } = JSON.parse(body)); completion = 0; res.end('{}'); return; }
    let p = {}; try { p = body ? JSON.parse(body) : {}; } catch {}
    const tools = p.tools?.map(t => t.function?.name ?? t.name) ?? null;
    const row = { scenario, method: req.method, path: req.url, model: p.model ?? null, auth: req.headers.authorization === 'Bearer fake-native-primary' ? 'typesafe-fake-primary' : req.headers.authorization === 'Bearer fake-or-trap' ? 'openrouter-fake' : req.headers.authorization ? 'other' : 'none', tools, hasTools: Array.isArray(tools) && tools.length > 0, sys: JSON.stringify(p.messages?.[0]?.content ?? '').slice(0, 160) };
    appendFileSync(log, JSON.stringify(row) + '\n');
    if (req.url.startsWith('/openrouter') || req.url.startsWith('/secondary')) { res.writeHead(503, { 'content-type': 'application/json' }); res.end('{"error":"trap contacted"}'); return; }
    if (req.method === 'GET') { res.setHeader('content-type', 'application/json'); res.end('{"data":[]}'); return; }
    if (req.url.endsWith('/v1/systemone') || req.url === '/guard') {
      if (typesafe === 'down') { res.writeHead(503, { 'content-type': 'application/json' }); res.end('{"error":"TypeSafe deliberately unavailable"}'); return; }
      const guard = req.url.startsWith('/guard/');
      const answers = Object.fromEntries(Object.entries(p.questions ?? {}).map(([id, q]) => {
        if (q.type === 'noul') return [id, { type: 'noul', noul: guard ? 0 : 0.95 }];
        const keys = Object.keys(q.criteria ?? {}); const pick = guard ? (keys.find(k => /allow|safe|no/i.test(k)) ?? keys.at(-1)) : keys[0];
        return [id, { type: 'choice', choice: pick, confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, +(k === pick)])) }];
      }));
      res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ model: 'jev-fake', answers, usage: { input_tokens: 3, output_tokens: 1, cost: 0 } })); return;
    }
    if (!req.url.endsWith('/chat/completions')) { res.writeHead(404); res.end('{}'); return; }
    res.setHeader('content-type', 'text/event-stream');
    const emit = choice => res.write(`data: ${JSON.stringify({ id: 'fx', object: 'chat.completion.chunk', created: 1, model: 'main', choices: [choice] })}\n\n`);
    const isTurn = row.hasTools;
    if (isTurn) completion++;
    const name = isTurn && completion === 1 && tool !== 'none' ? tools.find(n => n === tool) : undefined;
    if (name) {
      const args = tool === 'find' ? { query: scenario.includes('down') ? 'Locate addition helper while TypeSafe is down' : 'Adding two numbers for ' + scenario, grep_keywords: ['add'] } : { command: 'ls counter.ts' };
      emit({ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: 'call-1', type: 'function', function: { name, arguments: JSON.stringify(args) } }] }, finish_reason: null });
      emit({ index: 0, delta: {}, finish_reason: 'tool_calls' });
    } else {
      const text = isTurn ? (tool !== 'none' && completion === 1 ? `Tool ${tool} was not offered to me.` : `Done: scenario ${scenario} finished on the worker's own model.`) : 'helper reply';
      emit({ index: 0, delta: { role: 'assistant', content: text }, finish_reason: null });
      emit({ index: 0, delta: {}, finish_reason: 'stop' });
    }
    res.write('data: [DONE]\n\n'); res.end();
  });
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
