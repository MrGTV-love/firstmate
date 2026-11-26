// Private metadata-only attempt receipts. Callers set the schema and bind the
// journal to their launch identity. Never pass prompts, bodies or credentials.
import { createHash } from 'node:crypto';
import { closeSync, fsyncSync, openSync, writeFileSync } from 'node:fs';

export function requestIdDigest(id) {
  return typeof id === 'string' && /^[\x21-\x7e]{1,256}$/.test(id) && !id.includes(',')
    ? createHash('sha256').update(id).digest('hex') : null;
}

export function openAttemptJournal(path) {
  const fd = openSync(path, 'ax', 0o600);
  let incomplete = false;
  const append = (record) => {
    try {
      writeFileSync(fd, JSON.stringify(record) + '\n');
      fsyncSync(fd);
    } catch (error) {
      incomplete = true;
      throw error;
    }
  };
  return {
    append,
    observe(record) { try { append(record); } catch { /* Leave the journal unclosed. */ } },
    close(record) {
      try { if (!incomplete && record) append(record); } catch { /* Report below. */ }
      try { closeSync(fd); } catch { incomplete = true; }
      return !incomplete;
    },
  };
}
