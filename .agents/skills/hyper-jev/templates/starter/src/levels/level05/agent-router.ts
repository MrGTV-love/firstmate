/**
 * Level 5, option C: agent router.
 * Which harness handles the task: script, fast agent, reasoning agent, browser agent, or human. One call routes, scores ambiguity, and flags desktop access.
 */
import { jev } from "../../core/client.ts";
import { choice, noul, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, NoulAnswer, ScoreAnswer } from "../../core/types.ts";

export type AgentProfile =
  | "deterministic_script"
  | "fast_agent"
  | "reasoning_agent"
  | "browser_agent"
  | "human";

export type AgentRoute = {
  profile: AgentProfile;
  effort: number;
  needsDesktopAccess: boolean;
  rationale: string;
};

/** C: the agent router — one call decides which harness gets the task (the herdr workflow). */
export async function routeAgent(task: string, repoName: string): Promise<AgentRoute> {
  const { answers } = await jev.systemOne({ task, repository: repoName }, {
    profile: choice("Which workflow should handle `task` in `repository`?", {
      deterministic_script: "A script or existing tool answers it with no model at all",
      fast_agent: "A quick coding agent on a cheap model for localized changes like adding a feature or fixing a test",
      reasoning_agent: "A deep reasoning model for architecture or hard debugging",
      browser_agent: "Needs a browser or logged-in web applications",
      human: "Ambiguous, sensitive, or needs judgment the tools cannot make",
    }),
    ambiguity: score("How ambiguous is `task`?", [
      "Fully specified, unambiguous request",
      "Some interpretation needed but the goal is clear",
      "Open-ended; success depends on choices not stated in the request",
    ]),
    needs_desktop: noul("Does `task` require access to logged-in applications or the desktop?"),
  });
  return decideAgent(
    answers.profile as ChoiceAnswer,
    answers.ambiguity as ScoreAnswer,
    answers.needs_desktop as NoulAnswer
  );
}

export function decideAgent(profile: ChoiceAnswer, ambiguity: ScoreAnswer, needsDesktop: NoulAnswer): AgentRoute {
  const chosen = (profile.confidence < 0.5 ? "human" : profile.choice) as AgentProfile;
  return {
    profile: chosen,
    effort: Math.round(ambiguity.score * 100) / 100,
    needsDesktopAccess: needsDesktop.noul > 0.5,
    rationale: `${chosen} @ confidence ${profile.confidence.toFixed(2)}`,
  };
}
