/**
 * Level 9, option A: wikiracing.
 * The options are the page's real outgoing links, so the model cannot invent one. Pages with more than 255 links get pre-filtered in code first.
 */
import { jev } from "../../core/client.ts";
import { choice } from "../../core/helpers.ts";
import { LIMITS, type ChoiceAnswer } from "../../core/types.ts";

export interface WikiLink {
  title: string;
  snippet: string;
}

/** A: wikiracing. Options are the real outgoing links — the model cannot pick a link that doesn't exist. */
export async function pickWikiLink(
  currentPage: string,
  targetPage: string,
  links: WikiLink[]
): Promise<{ title: string; confidence: number; probabilities: Record<string, number> }> {
  if (links.length === 0) throw new Error("No links to choose from.");
  if (links.length > LIMITS.MAX_CHOICE_OPTIONS) {
    throw new Error(
      `${links.length} links exceeds the ${LIMITS.MAX_CHOICE_OPTIONS}-option Choice limit; pre-filter to the most plausible links in code first.`
    );
  }
  const criteria = Object.fromEntries(links.map((l) => [l.title, l.snippet]));
  const { answers } = await jev.systemOne(
    { current_page: currentPage, target_page: targetPage, links },
    {
      next_link: choice(
        `Which link in \`links\` most likely brings us closer from \`current_page\` to \`target_page\`?`,
        criteria
      ),
    }
  );
  const a = answers.next_link as ChoiceAnswer;
  return { title: a.choice, confidence: a.confidence, probabilities: a.probabilities };
}
