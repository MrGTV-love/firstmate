import { JevClient, type SystemOneResult } from "../core/client.ts";
import { choice } from "../core/helpers.ts";
import type { ChoiceAnswer } from "../core/types.ts";

export const SUPPORT_POLICY_VERSION = "support-routing-v1";
export const REVIEW_FLOOR = 0.65; // Example only. Calibrate on labeled tickets.
export const MAX_MESSAGE_BYTES = 8_192;

export const SUPPORT_QUESTIONS = {
  department: choice("Which team should handle the customer's message?", {
    technical: "Broken software, crashes, outages, or integration errors",
    billing: "Invoices, duplicate charges, refunds, or subscriptions",
    sales: "Pricing questions, upgrades, or new accounts",
    other: "No listed team fits, or the message lacks enough information",
  }),
};

export interface SupportDecision {
  route: "engineering" | "billing" | "sales" | "human";
  reason: string;
}

/** Pure application policy. A model label is never executable code. */
export function decideSupportRoute(answer: ChoiceAnswer): SupportDecision {
  if (!Number.isFinite(answer.confidence) || answer.confidence < REVIEW_FLOOR) {
    return { route: "human", reason: "Uncertain classification" };
  }
  switch (answer.choice) {
    case "technical": return { route: "engineering", reason: "Technical support" };
    case "billing": return { route: "billing", reason: "Billing support" };
    case "sales": return { route: "sales", reason: "Sales request" };
    default: return { route: "human", reason: "No approved automated route" };
  }
}

/** Validate untrusted input, ask one bounded question, retain the whole result. */
export async function routeSupport(
  client: JevClient,
  message: string,
  options: { signal?: AbortSignal } = {},
): Promise<{ decision: SupportDecision; result: SystemOneResult; policyVersion: string }> {
  if (typeof message !== "string" || !message.trim()) {
    throw new TypeError("A nonempty customer message is required");
  }
  if (Buffer.byteLength(message, "utf8") > MAX_MESSAGE_BYTES) {
    throw new RangeError("Customer message exceeds the service byte limit");
  }
  const result = await client.systemOne({ message }, SUPPORT_QUESTIONS, options);
  const answer = result.answers.department;
  if (answer.type !== "choice") throw new TypeError("Expected a department Choice answer");
  return { decision: decideSupportRoute(answer), result, policyVersion: SUPPORT_POLICY_VERSION };
}
