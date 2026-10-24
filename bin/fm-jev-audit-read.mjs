#!/usr/bin/env node
// Read legacy shared and current per-task audit rows without changing either.
// Usage: node bin/fm-jev-audit-read.mjs <state-dir>
// Rows are ordered by numeric `at`; ties retain source filename and line order.
// Missing individual logs are normal; malformed or unreadable logs fail loudly.
import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export function readGuardAudit(state) {
  const files = readdirSync(state).filter(name => name === 'jev-guard.jsonl'
    || /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}\.jev-guard\.jsonl$/.test(name)).sort();
  const rows = files.flatMap(file => readFileSync(resolve(state, file), 'utf8').split('\n')
    .filter(line => line.trim()).map(line => JSON.parse(line)));
  rows.sort((a, b) => (typeof a.at === 'number' ? a.at : 0) - (typeof b.at === 'number' ? b.at : 0));
  return rows.map(row => JSON.stringify(row) + '\n').join('');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.argv.length !== 3) {
    console.error('usage: node bin/fm-jev-audit-read.mjs <state-dir>');
    process.exitCode = 2;
  } else {
    process.stdout.write(readGuardAudit(process.argv[2]));
  }
}
