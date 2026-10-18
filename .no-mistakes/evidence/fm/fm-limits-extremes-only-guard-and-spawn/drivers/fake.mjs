import { createServer } from 'node:http';
import { appendFileSync, writeFileSync, readFileSync } from 'node:fs';
const [log, portFile] = process.argv.slice(2);
const seen = new Set();
const server = createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    if (body.includes('deadjudge')) { appendFileSync(log, JSON.stringify({ path: req.url, dead: true, body }) + '\n'); return; }
    const m = /delayms(\d+)/.exec(body);
    const delay = m ? Number(m[1]) : 0;
    setTimeout(() => handle(), delay);
    function handle() {
    appendFileSync(log, JSON.stringify({ path: req.url, auth: req.headers.authorization, body }) + '\n');
    const request = JSON.parse(body);
    const text = JSON.stringify(request.state);
    if (text.includes('timeout-reset')) {
      if (!seen.has(text)) { seen.add(text); return; }
      req.socket.destroy(); return;
    }
    if (text.includes('slow502')) { setTimeout(() => { res.statusCode = 502; res.end('{}'); }, 2500); return; }
    if (text.includes('fail500') || text.includes('http402')) { res.statusCode = text.includes('http402') ? 402 : 500; res.end('{}'); return; }
    if (text.includes('flaky-once') && !seen.has(text)) { seen.add(text); res.statusCode = 500; res.end('{}'); return; }
    if (text.includes('stall-direct')) return;
    if (text.includes('invalid-json')) { res.end('{'); return; }
    const risky = /rm -rf|IGNORE PREVIOUS|sk-live/.test(text);
    const probability = /probability=([0-9.]+)/.exec(text);
    const answers = {};
    for (const [id, q] of Object.entries(request.questions)) {
      if (q.type === 'noul') {
        answers[id] = { type: 'noul', noul: probability ? Number(probability[1]) : risky ? 0.95 : 0.05, extra: 'provider-private-canary' };
        continue;
      }
      const keys = Object.keys(q.criteria);
      const pick = risky && keys.includes('irreversible') ? 'irreversible' : keys[0];
      answers[id] = { type: 'choice', choice: pick, confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, k === pick ? 1 : 0])), extra: 'provider-private-canary' };
    }
    if (text.includes('missing-answer')) delete answers.injection;
    if (text.includes('invalid-answer')) answers.injection = { type: 'noul', noul: '0.01' };
    const usage = { input_tokens: 3, output_tokens: 1, extra: 'provider-private-canary' };
    if (text.includes('reported-cost')) usage.cost = 0.001;
    res.setHeader('content-type', 'application/json');
    const reply = () => res.end(JSON.stringify({ model: 'jev-fake', answers, usage, extra: 'provider-private-canary' }));
    if (text.includes('late-answer')) setTimeout(reply, 31000);
    else reply();
    }
  });
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
