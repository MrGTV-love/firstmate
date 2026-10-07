/**
 * Level 10, option C: the derived review rubric.
 * The agent invents its review rubric from the diff's shape. Auth surfaces, migrations, and secret-adjacent paths become options only when they exist.
 */
import { choice, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, ScoreAnswer } from "../../core/types.ts";
import { JevToolkit, type ChoiceOption } from "./toolkit.ts";

export interface DiffShape {
  filesChanged: number;
  linesAdded: number;
  linesDeleted: number;
  touches: string[]; // paths, discovered at runtime
  commitMessage: string;
}

/** The rubric is derived: the agent names the risks this diff actually carries. */
export function buildReviewRubric(diff: DiffShape) {
  const toolkit = new JevToolkit();
  const risks: ChoiceOption[] = [];
  if (diff.touches.some((p) => /auth|login|session|token/i.test(p))) {
    risks.push({ key: "auth_surface", description: "Touches authentication or session handling" });
  }
  if (diff.touches.some((p) => /migrat|schema|\.sql/i.test(p))) {
    risks.push({ key: "data_migration", description: "Changes the database schema" });
  }
  if (diff.touches.some((p) => /secret|key|credential|\.env/i.test(p))) {
    risks.push({ key: "secrets_adjacent", description: "Touches files adjacent to secrets" });
  }
  if (diff.linesDeleted > diff.linesAdded * 2) {
    risks.push({ key: "large_deletion", description: "Deletes far more than it adds" });
  }
  risks.push(
    { key: "routine_change", description: "An ordinary change within established patterns" },
    { key: "needs_human_judgment", description: "Carries a call a human should make" }
  );
  const block = toolkit.buildChoiceBlock(
    "What kind of review does `diff_shape` need, considering `commit_message` and `touched_paths`?",
    risks
  );
  const effort = score("How careful should the reviewer be with `diff_shape`?", [
    "Skim; mechanical change",
    "Read closely; logic changed",
    "Line-by-line with the spec open",
  ]);
  return { block, effort, derivedRisks: risks.map((r) => r.key) };
}

export async function judgePullRequest(diff: DiffShape): Promise<{
  reviewClass: string;
  effort: number;
  gate: "auto" | "confirm" | "human";
  derivedRisks: string[];
}> {
  const toolkit = new JevToolkit();
  const { block, effort, derivedRisks } = buildReviewRubric(diff);
  const { answers } = await toolkit.ask(
    { diff_shape: diff, commit_message: diff.commitMessage, touched_paths: diff.touches },
    { review_class: block, effort }
  );
  const reviewClass = answers.review_class as ChoiceAnswer;
  const effortAnswer = answers.effort as ScoreAnswer;
  return {
    reviewClass: reviewClass.choice,
    effort: effortAnswer.score,
    gate: toolkit.gate(reviewClass, { floor: 0.6, bar: 0.85 }),
    derivedRisks,
  };
}
