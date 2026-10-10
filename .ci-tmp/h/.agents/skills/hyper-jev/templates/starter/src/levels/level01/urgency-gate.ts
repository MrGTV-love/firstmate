/**
 * Level 1, option B: urgency gate.
 * One Noul, one threshold, one branch. Above 0.7 the page triggers. The threshold is yours to read and move.
 */
import { jev } from "../../core/client.ts";
import { noul } from "../../core/helpers.ts";
import type { NoulAnswer } from "../../core/types.ts";

export type UrgencyDecision = {
  act: boolean;
  noul: number;
};

/** B: is this urgent? One question, one threshold. Near 1 = strong yes, near 0.5 = the model can't tell. */
export async function urgentGate(message: string, threshold = 0.7): Promise<UrgencyDecision> {
  const { answers } = await jev.systemOne({ message }, {
    is_urgent: noul("Does `message` convey urgency or time-sensitivity?", {
      true: "Sender asks for action today, mentions losing money, customers, downtime, or a deadline",
      false: "No deadline, no consequence, a routine question",
    }),
  });

  const a = answers.is_urgent as NoulAnswer;
  return { act: a.noul >= threshold, noul: a.noul };
}
