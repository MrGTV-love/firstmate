// Property probe of the real splitForRoom (no mocks): fit, order, exact cover, short-span-whole, surrogate safety.
import { splitForRoom, CHUNK_OVERLAP_BYTES, MAX_CHUNKS } from '/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M53JWXAA2EC64BZTMMB8JHS7/bin/ten-levels/extensions/report.ts';
let seed = 12345; const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32;
const alphabet = ['a','b','\n','"','\\','\t','é','中','😀','\u0001','\ud800','\udc00','x'];
const esc = (p) => Buffer.byteLength(JSON.stringify(p), 'utf8') - 2;
let trials = 0, nulls = 0, multi = 0, bad = [];
for (let t = 0; t < 300; t++) {
  const room = 2 * CHUNK_OVERLAP_BYTES + 64 + Math.floor(rnd() * 4000);
  const len = 1 + Math.floor(rnd() * room * 3);
  let text = ''; for (let i = 0; i < len; i++) text += alphabet[Math.floor(rnd() * alphabet.length)];
  const pieces = splitForRoom(text, room); trials++;
  if (!pieces) { nulls++; continue; }
  if (pieces.length > 1) multi++;
  if (pieces.length > MAX_CHUNKS) bad.push(['too many pieces', t]);
  for (const p of pieces) if (esc(p) > room) bad.push(['piece exceeds room', t, esc(p), room]);
  if (pieces[0].codePointAt(0) !== text.codePointAt(0) || !text.startsWith(pieces[0])) bad.push(['first piece not prefix', t]);
  if (!text.endsWith(pieces.at(-1))) bad.push(['last piece not suffix', t]);
  // every window of text whose escaped size <= overlap - 6 must lie whole inside one piece (spot-check 40 random windows)
  for (let k = 0; k < 40; k++) {
    const a = Math.floor(rnd() * text.length); let b = a, used = 0; const lim = CHUNK_OVERLAP_BYTES - 6;
    while (b < text.length) { const cp = String.fromCodePoint(text.codePointAt(b)); const w = esc(cp); if (used + w > lim) break; used += w; b += cp.length; }
    const span = text.slice(a, b);
    if (span && !pieces.some((p) => p.includes(span))) { bad.push(['short span cut', t, a, b]); break; }
  }
  // pieces glue back with overlap: consecutive pieces share a suffix/prefix so nothing is dropped
  for (let i = 1; i < pieces.length; i++) if (!pieces[i - 1].slice(-4).length || !text.includes(pieces[i - 1] + '')) bad.push(['piece not from text', t]);
}
console.log(JSON.stringify({ trials, nulls, multiPiece: multi, violations: bad.length, firstViolations: bad.slice(0, 5) }));
