/**
 * Level 10, option B: the authored router.
 * The agent scans route targets and compiles every discovery into an option with a generated description. The router is not hand-written.
 */
import { choice } from "../../core/helpers.ts";
import type { ChoiceAnswer } from "../../core/types.ts";
import { JevToolkit } from "./toolkit.ts";

export interface RouteTarget {
  key: string;
  description: string;
}

/** The agent scans the environment and turns every discovered target into an option. */
export function authorRouterBlock(targets: RouteTarget[]) {
  const toolkit = new JevToolkit();
  return toolkit.buildChoiceBlock(
    "Which of the discovered targets should handle `task`?",
    targets.map((t) => ({ key: t.key, description: t.description }))
  );
}

export async function routeTaskWithAuthoredBlock(
  task: string,
  targets: RouteTarget[]
): Promise<{ target: string; confidence: number; gate: "auto" | "confirm" | "human" }> {
  const toolkit = new JevToolkit();
  const block = authorRouterBlock(targets);
  const { answers } = await toolkit.ask({ task }, { route: block });
  const a = answers.route as ChoiceAnswer;
  return { target: a.choice, confidence: a.confidence, gate: toolkit.gate(a, { floor: 0.55, bar: 0.85 }) };
}
