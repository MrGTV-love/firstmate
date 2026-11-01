// Disposable loopback TypeSafe endpoint: answers every noul question with 1
// (maximally positive), records each request.
import http from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
const [callsPath, portPath] = process.argv.slice(2);
http.createServer(async (req, res) => {
  let body = ''; for await (const c of req) body += c;
  const r = JSON.parse(body); appendFileSync(callsPath, JSON.stringify(r) + '\n');
  const answers = {};
  for (const [id, q] of Object.entries(r.questions)) {
    if (q.type === 'choice') answers[id] = { type: 'choice', choice: Object.keys(q.criteria)[0], confidence: .95, probabilities: Object.fromEntries(Object.keys(q.criteria).map((k, i) => [k, i ? 0 : 1])) };
    else if (q.type === 'score') answers[id] = { type: 'score', score: 0, confidence: .95, probabilities: Object.fromEntries(q.criteria.map((_, i) => [i, i ? 0 : 1])), legend: Object.fromEntries(q.criteria.map((s, i) => [i, s])) };
    else answers[id] = { type: 'noul', noul: id === 'needs_desktop' ? 0 : 1 };
  }
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ model: 'jev-1.13.0', answers, usage: { input_tokens: 100, output_tokens: 20 } }));
}).listen(0, '127.0.0.1', function () { writeFileSync(portPath, String(this.address().port)); });
