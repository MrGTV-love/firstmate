/**
 * Level 3, option B: code-review risk.
 * Security risk, complexity, convention drift, commit-message quality, weighted into one number with a human-review threshold at 0.5.
 */
import { jev } from "../../core/client.ts";
import { score } from "../../core/helpers.ts";
import type { ScoreAnswer } from "../../core/types.ts";
import { normalized } from "./normalize.ts";

export const CODE_REVIEW_QUESTIONS = {
  security_risk: score("How much security risk does `diff` carry?", [
    "No surface touched that handles input, auth, or secrets",
    "Handles input or auth, but follows existing safe patterns",
    "Introduces a plausible injection, secret leak, auth bypass, or invalid token handling",
  ]),
  complexity: score("How complex is the change in `diff`?", [
    "Small, local change in one file, obvious on first read",
    "Touches several files, session handling, or adds branching",
    "Cross-cutting change with subtle invariants",
  ]),
  bad_practice: score("Does `diff` follow the conventions in `diff`'s surrounding context?", [
    "Follows existing patterns cleanly",
    "Minor style drift from surrounding code",
    "Works against the established patterns",
  ]),
};

/** B: code review risk matrix, one request per file diff. */
export async function codeReviewRisk(diff: string, commitMessage: string): Promise<{
  risk: number;
  needsHumanReview: boolean;
}> {
  const { answers } = await jev.systemOne({ diff, commit_message: commitMessage }, {
    ...CODE_REVIEW_QUESTIONS,
    commit_quality: score("Does `commit_message` accurately describe `diff`?", [
      "Vague or unrelated to the change",
      "Names the area but misses key parts of the change",
      "Accurately covers the change: names the fix, the session or token work, and the files",
    ]),
  });
  const w = { security_risk: 0.5, complexity: 0.2, bad_practice: 0.1, commit_quality: 0.2 };
  const parts = {
    security_risk: normalized(answers.security_risk as ScoreAnswer),
    complexity: normalized(answers.complexity as ScoreAnswer),
    bad_practice: normalized(answers.bad_practice as ScoreAnswer),
    commit_quality: 1 - normalized(answers.commit_quality as ScoreAnswer), // low quality = high risk
  };
  const risk = Object.entries(w).reduce((acc, [k, weight]) => acc + weight * parts[k as keyof typeof parts], 0);
  return { risk: Math.round(risk * 100) / 100, needsHumanReview: risk >= 0.5 };
}
