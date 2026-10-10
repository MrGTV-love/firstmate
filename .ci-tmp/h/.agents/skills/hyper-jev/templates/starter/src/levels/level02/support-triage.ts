/**
 * Level 2, option A: support triage.
 * Three questions about one ticket, one call: category, is the author blocked, how frustrated. Code turns the three answers into a route and a priority.
 */
import { jev } from "../../core/client.ts";
import { choice, noul, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, NoulAnswer, ScoreAnswer } from "../../core/types.ts";

export type Route = "engineering" | "billing" | "product" | "human";

export type TicketTriage = {
  route: Route;
  priority: "high" | "normal";
};

/** Which team each category goes to. The choice maps straight onto a code path. */
const ROUTES: Record<string, Route> = {
  bug_report: "engineering",
  billing: "billing",
  feature_request: "product",
  other: "human",
};

/** A: three questions, one call. Blocked or angry is high priority, whatever the category. */
export async function triageTicket(ticket: string): Promise<TicketTriage> {
  const { answers } = await jev.systemOne({ ticket }, {
    category: choice("What kind of ticket is `ticket`?", {
      bug_report: "Something is broken, crashes, freezes, or behaves wrong",
      billing: "Charges, invoices, refunds, subscriptions",
      feature_request: "Asks for something that does not exist yet",
      other: "None of the above",
    }),
    is_blocked: noul("Is the author of `ticket` unable to get their work done?", {
      true: "Cannot proceed, feature broken with no workaround, losing money or customers",
      false: "Can keep working, cosmetic, a question, or a suggestion",
    }),
    frustration: score("How frustrated is the author of `ticket`?", [
      "Calm, just stating facts",
      "Frustrated but civil",
      "Very angry, strong language, or threatening to leave",
    ]),
  });

  const category = answers.category as ChoiceAnswer;
  const blocked = answers.is_blocked as NoulAnswer;
  const frustration = answers.frustration as ScoreAnswer;

  const high = blocked.noul > 0.5 || frustration.score > 1.5;
  return { route: ROUTES[category.choice], priority: high ? "high" : "normal" };
}
