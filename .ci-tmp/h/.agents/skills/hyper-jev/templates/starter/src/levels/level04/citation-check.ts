/**
 * Level 4, option C: citation check.
 * Does the source support the claim, and is the quote faithful? Low confidence flags the citation for review instead of failing silently.
 */
import { jev } from "../../core/client.ts";
import { choice, score } from "../../core/helpers.ts";
import type { ChoiceAnswer, ScoreAnswer } from "../../core/types.ts";
import { CONFIDENCE } from "./confidence.ts";

export type CitationVerdict = {
  supported: boolean;
  flagForReview: boolean;
  confidence: number;
};

/** C: catch wrong or hallucinated citations. One Choice decides; confidence flags for review. */
export async function checkCitation(claim: string, quote: string, sourceContext: string): Promise<CitationVerdict> {
  const { answers } = await jev.systemOne({ claim, quote, source_context: sourceContext }, {
    supports: choice("Does `source_context` around `quote` support `claim`?", {
      supports: "The context clearly states or implies the claim",
      contradicts: "The context states the opposite of the claim",
      unrelated: "The context does not address the claim either way",
    }),
    quote_accuracy: score("How faithful is `quote` to the wording in `source_context`?", [
      "Paraphrased or altered in a way that changes meaning",
      "Loose but preserves meaning",
      "Verbatim or trivially elided",
    ]),
  });
  return decideCitation(answers.supports as ChoiceAnswer, answers.quote_accuracy as ScoreAnswer);
}

export function decideCitation(supports: ChoiceAnswer, quoteAccuracy: ScoreAnswer): CitationVerdict {
  const supported = supports.choice === "supports" && supports.confidence >= 0.6 && quoteAccuracy.score >= 1;
  return {
    supported,
    flagForReview: supports.confidence < CONFIDENCE.REVIEW_FLOOR || quoteAccuracy.confidence < 0.5,
    confidence: Math.min(supports.confidence, quoteAccuracy.confidence),
  };
}
