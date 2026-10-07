/**
 * Level 1, option C: ticket classifier.
 * One Choice over four departments. The answer is always one of them. An other option gives the model an exit.
 */
import { jev } from "../../core/client.ts";
import { choice } from "../../core/helpers.ts";
import type { ChoiceAnswer } from "../../core/types.ts";

export type Department = "billing" | "technical" | "sales" | "other";

/** C: route to exactly one department. A Choice maps straight onto code paths — no parsing. */
export async function classifyTicket(message: string): Promise<{ department: Department; confidence: number }> {
  const { answers } = await jev.systemOne({ message }, {
    department: choice("Which team should handle `message`?", {
      billing: "Charges, invoices, refunds, subscriptions, duplicate payments",
      technical: "Bugs, outages, crashes, integration problems, endpoints returning 500 errors",
      sales: "Pricing questions, upgrades, new accounts",
      other: "None of the above", // the escape hatch — always give the model an exit
    }),
  });

  const a = answers.department as ChoiceAnswer;
  return { department: a.choice as Department, confidence: a.confidence };
}
