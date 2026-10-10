/**
 * Level 3, option A: ticket priority.
 * Severity 0.6, frustration 0.3, report quality 0.1. Each a Score with situational levels, combined by weights a reviewer can read in one line.
 */
import { jev } from "../../core/client.ts";
import { score } from "../../core/helpers.ts";
import type { ScoreAnswer } from "../../core/types.ts";
import { normalized } from "./normalize.ts";

export const PRIORITY_QUESTIONS = {
  severity: score("How severe is the issue in `ticket`?", [
    "Cosmetic; no impact on functionality",
    "Broken or degraded feature, but a workaround exists",
    "Blocking issue; no workaround exists",
  ]),
  frustration: score("How frustrated is the author of `ticket`?", [
    "Calm, just stating facts",
    "Frustrated but civil",
    "Very angry or threatening to leave",
  ]),
  report_quality: score("How much does `ticket` give an engineer to work with?", [
    "No detail; just says something is broken",
    "Names the feature but no steps or environment",
    "Steps to reproduce or environment, but not both",
    "Steps to reproduce and environment",
  ]),
};

export const PRIORITY_WEIGHTS = { severity: 0.6, frustration: 0.3, report_quality: 0.1 };

/** A: ticket priority. Weights are visible, reviewable, and yours. */
export async function ticketPriority(ticket: string): Promise<{ priority: number; parts: Record<string, number> }> {
  const { answers } = await jev.systemOne({ ticket }, PRIORITY_QUESTIONS);
  return combinePriority({
    severity: answers.severity as ScoreAnswer,
    frustration: answers.frustration as ScoreAnswer,
    report_quality: answers.report_quality as ScoreAnswer,
  });
}

export function combinePriority(a: Record<keyof typeof PRIORITY_WEIGHTS, ScoreAnswer>): {
  priority: number;
  parts: Record<string, number>;
} {
  const parts = {
    severity: normalized(a.severity),
    frustration: normalized(a.frustration),
    report_quality: normalized(a.report_quality),
  };
  const priority =
    PRIORITY_WEIGHTS.severity * parts.severity +
    PRIORITY_WEIGHTS.frustration * parts.frustration +
    PRIORITY_WEIGHTS.report_quality * parts.report_quality;
  return { priority: Math.round(priority * 100) / 100, parts };
}
