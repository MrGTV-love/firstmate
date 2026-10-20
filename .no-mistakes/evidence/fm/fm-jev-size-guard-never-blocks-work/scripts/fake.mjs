import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
const [log, portFile] = process.argv.slice(2);
createServer((req, res) => {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    const request = JSON.parse(body);
    appendFileSync(log, JSON.stringify({ bytes: Buffer.byteLength(body), content: request.state.content ?? null, command: request.state.command ?? null, keys: Object.keys(request.state) }) + '\n');
    const text = JSON.stringify(request.state);
    const risky = /rm -rf|IGNORE PREVIOUS/.test(text);
    const answers = {};
    for (const [id, q] of Object.entries(request.questions)) {
      if (q.type === 'noul') { answers[id] = { type: 'noul', noul: risky ? 0.95 : 0.05 }; continue; }
      const keys = Object.keys(q.criteria);
      const pick = risky && keys.includes('irreversible') ? 'irreversible' : keys[0];
      answers[id] = { type: 'choice', choice: pick, confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, k === pick ? 1 : 0])) };
    }
    if (text.includes('fail500')) { res.statusCode = 500; res.end('{}'); return; }
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ model: 'jev-fake', answers, usage: { input_tokens: 3, output_tokens: 1 } }));
  });
}).listen(0, '127.0.0.1', function () { writeFileSync(portFile, String(this.address().port)); });
