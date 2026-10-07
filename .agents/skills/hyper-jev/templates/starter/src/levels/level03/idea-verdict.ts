/**
 * Level 3, option C: idea verdict.
 * Problem, demand, monetization, differentiation. Four Scores, one weighted number, three bands: kill, fix, ship.
 */
import { jev } from "../../core/client.ts";
import { score } from "../../core/helpers.ts";
import type { ScoreAnswer } from "../../core/types.ts";
import { normalized } from "./normalize.ts";

export const IDEA_QUESTIONS = {
  problem: score("How real is the problem described in `pitch`?", [
    "Hypothetical; no evidence anyone has this problem",
    "Real problem, but people live with it",
    "Painful, frequent, and people pay to solve it today",
  ]),
  demand: score("How much demand is there for the solution in `pitch`?", [
    "Tiny or unproven audience",
    "Visible niche audience",
    "Large audience actively searching for this",
  ]),
  monetization: score("How credible is the monetization in `pitch`?", [
    "No revenue model or unrealistic one",
    "Plausible model, unproven pricing",
    "Proven buyers or comparable revenue",
  ]),
  differentiation: score("How differentiated is `pitch` from existing alternatives?", [
    "Crowded space, no wedge",
    "A narrow wedge against incumbents",
    "A structural advantage incumbents cannot copy",
  ]),
};

/** C: the startup-idea judge. Ten questions exist in the wild; four carry the point. */
export async function ideaVerdict(pitch: string): Promise<{ verdict: "kill" | "fix" | "ship"; score: number }> {
  const { answers } = await jev.systemOne({ pitch }, IDEA_QUESTIONS);
  const w = { problem: 0.35, demand: 0.25, monetization: 0.2, differentiation: 0.2 };
  const total = (Object.keys(w) as (keyof typeof w)[]).reduce(
    (acc, k) => acc + w[k] * normalized(answers[k] as ScoreAnswer),
    0
  );
  const s = Math.round(total * 100) / 100;
  return { verdict: s >= 0.7 ? "ship" : s >= 0.4 ? "fix" : "kill", score: s };
}
