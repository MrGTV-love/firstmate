// Local stand-in for the paid TypeSafe endpoint. Records each request and
// answers every question from a settings file keyed by question id.
import http from 'node:http';
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
const [settingsPath, callsPath, portPath] = process.argv.slice(2);
const server = http.createServer(async (req, res) => {
  let body = ''; for await (const c of req) body += c;
  const request = JSON.parse(body), s = JSON.parse(readFileSync(settingsPath, 'utf8'));
  appendFileSync(callsPath, JSON.stringify({ path: req.url, request }) + '\n');
  const answers = {};
  for (const [id, q] of Object.entries(request.questions)) {
    if (q.type === 'choice') {
      const c = s[id] ?? 'fast';
      answers[id] = { type: 'choice', choice: c, confidence: .95, probabilities: Object.fromEntries(Object.keys(q.criteria).map(k => [k, k === c ? 1 : 0])) };
    } else if (q.type === 'score') {
      const n = s[id] ?? 0;
      answers[id] = { type: 'score', score: n, confidence: .95, probabilities: Object.fromEntries(q.criteria.map((_, i) => [i, i === n ? 1 : 0])), legend: Object.fromEntries(q.criteria.map((t, i) => [i, t])) };
    } else answers[id] = { type: 'noul', noul: s[id] ?? 0 };
  }
  Object.assign(answers, s.extra ?? {});
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ model: 'jev-1.13.0', answers, usage: { input_tokens: 100, output_tokens: 20 } }));
});
server.listen(0, '127.0.0.1', () => writeFileSync(portPath, String(server.address().port)));
