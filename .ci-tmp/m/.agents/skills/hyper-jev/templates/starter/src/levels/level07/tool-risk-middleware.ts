/**
 * Level 7, option C: tool-risk middleware.
 * Every agent tool call classified read only, contained, external, or destructive with a blast-radius Score, before it executes. The AutoMode pattern, opened up.
 */
import { jev } from "../../core/client.ts";
import { choice, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, ScoreAnswer } from "../../core/types.ts";

/** C: the AutoMode pattern. A middleware that wraps tool execution with a Jev risk gate. */
export interface ToolCall {
  tool: string;
  args: Record<string, unknown>;
}

export type ToolDecision =
  | { kind: "execute" }
  | { kind: "confirm"; reason: string }
  | { kind: "block"; reason: string };

export const TOOL_RISK_FLOOR = 0.5;

export const TOOL_RISK_BAR = 0.9;

/** One shared request classifies the call and scores its blast radius. */
export async function toolRiskMiddleware(
  call: ToolCall,
  availableTools: string[]
): Promise<ToolDecision> {
  const { answers } = await jev.systemOne(
    { call, available_tools: availableTools },
    {
      risk: choice("What is the worst realistic effect of executing `call`?", {
        read_only: "Inspects or reads; changes nothing",
        contained: "Changes state inside the project; recoverable",
        external_side_effect: "Sends messages, spends money, deploys, or notifies others",
        destructive: "Force-pushes, rewrites git history, deletes data, or cannot be undone",
      }),
      blast_radius: score("How many people or systems would feel a mistake in `call`?", [
        "Only this session; a mistake is invisible",
        "The project; a mistake means lost work",
        "Other people or production systems; a mistake is felt outside",
      ]),
    }
  );
  return decideToolCall(answers.risk as ChoiceAnswer, answers.blast_radius as ScoreAnswer);
}

export function decideToolCall(risk: ChoiceAnswer, blast: ScoreAnswer): ToolDecision {
  if (risk.confidence < TOOL_RISK_FLOOR) {
    return { kind: "confirm", reason: `unclassifiable at confidence ${risk.confidence.toFixed(2)}` };
  }
  if (risk.choice === "destructive") {
    return { kind: "block", reason: `destructive: ${risk.probabilities.destructive.toFixed(2)}` };
  }
  if (risk.choice === "external_side_effect" && risk.confidence < TOOL_RISK_BAR) {
    return { kind: "confirm", reason: "external effect below the auto bar" };
  }
  if (blast.score > 1.5 && risk.choice !== "read_only") {
    return { kind: "confirm", reason: "blast radius beyond the project" };
  }
  return { kind: "execute" };
}
