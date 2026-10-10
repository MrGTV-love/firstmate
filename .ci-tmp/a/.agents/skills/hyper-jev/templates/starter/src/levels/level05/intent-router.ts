/**
 * Level 5, option A: intent router.
 * Order status never touches an LLM. Product questions get a context-loaded LLM path. Complaints use a second Score to pick LLM or human.
 */
import { jev } from "../../core/client.ts";
import { choice, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, ScoreAnswer } from "../../core/types.ts";

export type IntentRoute =
  | { handler: "lookup"; reason: string }
  | { handler: "llm"; context: string }
  | { handler: "human"; reason: string };

/** A: intent routing. The order lookup never touches an LLM. */
export async function routeIntent(message: string): Promise<IntentRoute> {
  const { answers } = await jev.systemOne({ message }, {
    intent: choice("What does the author of `message` want?", {
      order_status: "Where is my order, has it shipped, tracking",
      product_question: "How a product works, compatibility, specs",
      return_exchange: "Return, exchange, or replace an item",
      complaint: "Unhappy with service or product, wants a resolution",
    }),
    needs_reasoning: score("How much thought does a good answer to `message` need?", [
      "A lookup or a one-line fact",
      "A short explanation using product knowledge",
      "A judgment call with trade-offs or an unhappy customer",
    ]),
  });
  return decideIntent(answers.intent as ChoiceAnswer, answers.needs_reasoning as ScoreAnswer);
}

export function decideIntent(intent: ChoiceAnswer, needsReasoning: ScoreAnswer): IntentRoute {
  if (intent.confidence < 0.5) {
    return { handler: "human", reason: "unclear intent" };
  }
  switch (intent.choice) {
    case "order_status":
      return { handler: "lookup", reason: "database answerable" };
    case "product_question":
      return { handler: "llm", context: "PRODUCT_CONTEXT" };
    case "return_exchange":
      return { handler: "llm", context: "RETURNS_CONTEXT" };
    case "complaint":
      return needsReasoning.score > 1
        ? { handler: "human", reason: "judgment call with an unhappy customer" }
        : { handler: "llm", context: "COMPLAINT_CONTEXT" };
    default:
      return { handler: "human", reason: "no matching intent" };
  }
}
