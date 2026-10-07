/**
 * Level 6, option C: adaptive form.
 * The user's answer chooses which controls come next: security questionnaire for enterprise, integration checklist for teams, free text otherwise.
 */
import { jev } from "../../core/client.ts";
import { choice, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, ScoreAnswer } from "../../core/types.ts";

export type FormControl =
  | "company_details"
  | "pricing_tier"
  | "integration_checklist"
  | "security_questionnaire"
  | "free_text";

/** C: adaptive intake form. The user's answer decides which controls come next. */
export async function adaptiveForm(userAnswer: string): Promise<{ controls: FormControl[]; rationale: string }> {
  const { answers } = await jev.systemOne({ answer: userAnswer }, {
    intent: choice("What is the person behind `answer` asking for?", {
      enterprise_evaluation: "Evaluating for a company: security, compliance, procurement",
      small_team_trial: "A small team trying the product on a real project",
      solo_hobby: "An individual exploring or learning",
      support_issue: "Something is broken or confusing and they need help",
    }),
    readiness: score("How ready is the person in `answer` to buy?", [
      "Exploring; no timeline or budget",
      "Comparing options with a rough timeline",
      "Has budget and a near-term decision date",
    ]),
  });
  return decideForm(answers.intent as ChoiceAnswer, answers.readiness as ScoreAnswer);
}

export function decideForm(intent: ChoiceAnswer, readiness: ScoreAnswer): {
  controls: FormControl[];
  rationale: string;
} {
  switch (intent.choice) {
    case "enterprise_evaluation":
      return {
        controls: ["security_questionnaire", "pricing_tier", "company_details"],
        rationale: "enterprise path",
      };
    case "small_team_trial":
      return {
        controls: readiness.score > 1 ? ["pricing_tier", "integration_checklist"] : ["integration_checklist", "free_text"],
        rationale: `small team, readiness ${readiness.score}`,
      };
    case "support_issue":
      return { controls: ["free_text"], rationale: "support path" };
    default:
      return { controls: ["free_text"], rationale: "solo path" };
  }
}
