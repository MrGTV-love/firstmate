/**
 * Level 4, option A: account actions.
 * The docs' canonical ladder: check_balance runs above the floor, approve_transfer needs the 0.9 bar to run without a confirmation click.
 */
import { jev } from "../../core/client.ts";
import { choice } from "../../core/helpers.ts";
import type { ChoiceAnswer } from "../../core/types.ts";
import { CONFIDENCE } from "./confidence.ts";

export type AccountAction =
  | { kind: "auto"; action: string }
  | { kind: "confirm"; action: string }
  | { kind: "human"; reason: string };

/** A: route a user message to an account action, gated by confidence. */
export async function routeAccountAction(userMessage: string): Promise<AccountAction> {
  const { answers } = await jev.systemOne({ message: userMessage }, {
    action: choice("What is the user trying to do in `message`?", {
      check_balance: "View the account balance",
      approve_transfer: "Approve the pending withdrawal",
      support: "Get help with a problem",
    }),
  });
  return decideAccountAction(answers.action as ChoiceAnswer);
}

export function decideAccountAction(a: ChoiceAnswer): AccountAction {
  if (a.confidence < CONFIDENCE.REVIEW_FLOOR) {
    return { kind: "human", reason: `low confidence (${a.confidence.toFixed(2)})` };
  }
  if (a.choice === "approve_transfer") {
    // Destructive path: only auto-execute above the bar.
    if (a.confidence > CONFIDENCE.DESTRUCTIVE_BAR) return { kind: "auto", action: "approve_transfer" };
    return { kind: "confirm", action: "approve_transfer" };
  }
  return { kind: "auto", action: a.choice };
}
