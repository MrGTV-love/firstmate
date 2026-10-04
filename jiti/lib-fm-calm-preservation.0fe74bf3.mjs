"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.CALM_PRESERVE_MIN_CHARS = void 0;exports.calmTextIsSubstantive = calmTextIsSubstantive; // Shared Calm policy for deciding whether mid-turn assistant text is substantive.
// Claude Code imports this file directly, while the Pi extension reaches the same
// implementation through its tracked symlink so both harnesses keep one threshold and rule.

/** The minimum trimmed text length preserved from a mid-turn assistant message. */
const CALM_PRESERVE_MIN_CHARS = exports.CALM_PRESERVE_MIN_CHARS = 240;

/** Whether mid-turn assistant text is substantive enough to remain visible. */
function calmTextIsSubstantive(text) {
  return text.includes("\n") || text.trim().length >= CALM_PRESERVE_MIN_CHARS;
} /* v9-78b4d19cf646260f */
