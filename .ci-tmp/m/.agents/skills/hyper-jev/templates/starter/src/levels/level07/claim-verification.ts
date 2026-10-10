/**
 * Level 7, option A: claim verification.
 * The LLM writes the summary, Jev checks each claim against the transcript. One Noul per claim, one request. Low-probability claims queue for review.
 */
import { jev } from "../../core/client.ts";
import { noul } from "../../core/helpers.ts";
import type { NoulAnswer } from "../../core/types.ts";

export interface ClaimCheck {
  claim: string;
  supported: boolean;
  needsReview: boolean;
}

/** A: podcast/blog claim checking. The LLM writes the summary; Jev checks each claim
 *  against the transcript. One Noul per claim, one request — the claims live in the
 *  instructions, the transcript alone is the state, so no claim can echo itself. */
export async function verifyClaims(claims: string[], transcript: string): Promise<ClaimCheck[]> {
  const questions = Object.fromEntries(
    claims.map((c, i) => [
      `claim_${i}`,
      noul(`Does the transcript in \`transcript\` support this claim: "${c}"?`, {
        true: "The transcript states or directly implies the claim",
        false: "The transcript contradicts the claim or is unrelated to it",
      }),
    ])
  );
  const { answers } = await jev.systemOne({ transcript }, questions);
  return claims.map((claim, i) => {
    const p = (answers[`claim_${i}`] as NoulAnswer).noul;
    return { claim, supported: p > 0.7, needsReview: p <= 0.7 && p >= 0.4 };
  });
}
