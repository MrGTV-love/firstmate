/**
 * Level 4, shared: the two confidence thresholds every gate on this level reads.
 */

export const CONFIDENCE = {
  REVIEW_FLOOR: 0.5, // below this: don't act, ask a human
  DESTRUCTIVE_BAR: 0.9, // above this: act without confirmation
} as const;
