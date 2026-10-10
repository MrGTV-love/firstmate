/**
 * Level 6, option B: feed filter.
 * Per post: genuine, rage bait, promo, political argument, plus a would-readers-be-worse-off Noul. Hide the engineered ones, keep the real ones.
 */
import { jev } from "../../core/client.ts";
import { choice, noul } from "../../core/helpers.ts";
import type { ChoiceAnswer, NoulAnswer } from "../../core/types.ts";

export interface FeedItem {
  id: string;
  author: string;
  text: string;
}

export interface FeedVerdict {
  id: string;
  hide: boolean;
  reason: string;
}

/** B: the feed-filter extension. Per post, one call, user-defined categories. */
export async function filterFeed(items: FeedItem[]): Promise<FeedVerdict[]> {
  // One request per post — the state differs per item, so they cannot batch.
  return Promise.all(
    items.map(async (item) => {
      const { answers } = await jev.systemOne({ ...item }, {
        category: choice("What kind of post is `text`?", {
          genuine: "A real share, question, or honest take",
          rage_bait: "Engineered to provoke anger, outrage, or insults for engagement",
          promo: "Promotion of a product, crypto, or course",
          political_argument: "Partisan point-scoring rather than discussion",
        }),
        hide_confidence: noul("Would most readers be worse off having seen `text`?"),
      });
      const category = answers.category as ChoiceAnswer;
      const hide =
        (category.choice !== "genuine" && category.confidence > 0.6) ||
        (answers.hide_confidence as NoulAnswer).noul > 0.75;
      return { id: item.id, hide, reason: category.choice };
    })
  );
}
