/**
 * Level 9, option C: shortlist re-ranking.
 * One Score per query-candidate pair over a BM25 shortlist. Isolated state per candidate, no cross-talk. Top-1 accuracy from 5% to 18% in the cookbook.
 */
import { jev } from "../../core/client.ts";
import { score } from "../../core/helpers.ts";
import type { ScoreAnswer } from "../../core/types.ts";

export interface Candidate {
  id: string;
  text: string;
}

export interface RerankResult {
  id: string;
  score: number;
  keep: boolean;
}

/**
 * C: re-ranking, from the TypeSafe cookbook: BM25 shortlists of 30 passages,
 * one Score per query-candidate pair, top-1 accuracy from 5% to 18%. Each
 * candidate gets its own small request — isolated state, no cross-talk
 * between candidates.
 */
export async function rerankShortlist(
  query: string,
  candidates: Candidate[],
  keepThreshold = 1.0
): Promise<RerankResult[]> {
  const scored = await Promise.all(
    candidates.map(async (c) => {
      const { answers } = await jev.systemOne({ query, candidate: c.text }, {
        fit: score("How well does `candidate` answer `query`?", [
          "Not about the question at all, like a company history page",
          "Topically related but does not answer it, like mentioning support without the policy",
          "Contains a direct answer: states the refund window, terms, or policy the query asks for, like refunds available within 30 days",
        ]),
      });
      return { id: c.id, score: (answers.fit as ScoreAnswer).score };
    })
  );
  return scored
    .map((s) => ({ ...s, keep: s.score >= keepThreshold }))
    .sort((a, b) => b.score - a.score);
}
