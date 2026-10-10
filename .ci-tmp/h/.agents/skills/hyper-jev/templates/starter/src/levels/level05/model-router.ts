/**
 * Level 5, option B: model router.
 * Choose the least costly model that can complete the task, plus an effort Score for reasoning depth. The middleware LangChain shipped in week one.
 */
import { jev } from "../../core/client.ts";
import { choice, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, ScoreAnswer } from "../../core/types.ts";

export type ModelRoute = {
  model: "fast" | "powerful";
  effort: "low" | "high";
  rationale: string;
};

/** B: the model router — the use case LangChain shipped as ModelRouterMiddleware. */
export async function routeModel(task: string): Promise<ModelRoute> {
  const { answers } = await jev.systemOne({ task }, {
    model: choice("Choose the least costly model that can complete `task`.", {
      fast: "Direct lookups, extraction, localized changes",
      powerful: "Architecture, cross-file reasoning, high-stakes decisions",
    }),
    effort: score("How much reasoning effort does `task` need?", [
      "Immediate answer, single fact or mechanical change",
      "Some investigation across a few files",
      "Deep multi-step reasoning with trade-offs",
    ]),
  });
  return decideModel(answers.model as ChoiceAnswer, answers.effort as ScoreAnswer);
}

export function decideModel(model: ChoiceAnswer, effort: ScoreAnswer): ModelRoute {
  return {
    model: model.choice === "powerful" ? "powerful" : "fast",
    effort: effort.score > 1 ? "high" : "low",
    rationale: `${model.choice} @ confidence ${model.confidence.toFixed(2)}, effort score ${effort.score}`,
  };
}
