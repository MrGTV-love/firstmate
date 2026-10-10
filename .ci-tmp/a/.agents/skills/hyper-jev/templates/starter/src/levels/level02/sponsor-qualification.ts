/**
 * Level 2, option C: sponsor-form qualification.
 * Is it a sponsor inquiry, what product category, how specific is the ask? One call decides auto-reply or manual review.
 */
import { jev } from "../../core/client.ts";
import { choice, noul, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, NoulAnswer, ScoreAnswer } from "../../core/types.ts";

export interface SponsorQualification {
  autoReply: boolean;
  isSponsor: boolean;
  category: string;
  specificity: number;
}

/** C: the sponsor-form example from the field — one request, three independent judgments. */
export async function qualifySponsorForm(form: {
  name: string;
  description: string;
  opportunity: string;
}): Promise<SponsorQualification> {
  const { answers } = await jev.systemOne(form, {
    // Write the exact condition: "request or propose" reads 0.98 vs 0.01 live,
    // where "ask to sponsor" literally scored only 0.84 on the same message.
    is_sponsor_inquiry: noul("Does `description` request or propose sponsorship of the site or newsletter?", {
      true: "The sender wants to pay for placement in the site or newsletter",
      false: "A question, a support issue, or a request unrelated to sponsorship",
    }),
    product_category: choice("What kind of product is described by `name` and `description`?", {
      dev_tool: "Developer tools, hosting, APIs, SaaS for developers",
      course: "Courses, books, or training",
      unrelated: "Anything not aimed at developers",
    }),
    message_quality: score("How specific is the request in `description`?", [
      "Generic template, no reference to this site",
      "Mentions the site but no concrete ask",
      "Concrete ask with a timeframe or product named",
    ]),
  });
  // Threshold tuned against the live model (0.98 on a real inquiry, 0.01 on a non-inquiry);
  // the mock stand-in reads ~0.90 on the same message.
  const isSponsor = (answers.is_sponsor_inquiry as NoulAnswer).noul > 0.8;
  const category = (answers.product_category as ChoiceAnswer).choice;
  const specificity = (answers.message_quality as ScoreAnswer).score;
  return {
    isSponsor,
    category,
    specificity,
    autoReply: isSponsor && category === "dev_tool" && specificity >= 1.5,
  };
}
