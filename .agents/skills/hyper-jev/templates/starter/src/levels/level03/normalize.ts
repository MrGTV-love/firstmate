/**
 * Level 3, shared: normalize a Score answer to 0 to 1 against its own top level, so scales of different lengths compare.
 */
import { score } from "../../core/helpers.ts";
import type { ScoreAnswer } from "../../core/types.ts";

/** Normalize a score answer to 0-1 against its own top level, so scales of different lengths compare. */
export function normalized(answer: ScoreAnswer): number {
  const topLevel = Object.keys(answer.legend).length - 1;
  return topLevel === 0 ? 0 : answer.score / topLevel;
}
