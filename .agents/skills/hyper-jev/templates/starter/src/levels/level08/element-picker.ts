/**
 * Level 8, option B: element picker.
 * The planner LLM sets the goal. Jev picks the next element to act on from the live DOM, as a Choice over element indices built at runtime.
 */
import { jev } from "../../core/client.ts";
import { choice } from "../../core/helpers.ts";
import type { ChoiceAnswer } from "../../core/types.ts";

export interface PageElement {
  selector: string;
  role: string;
  text: string;
}

export interface ElementPick {
  selector: string;
  confidence: number;
}

/**
 * B: browser automation. The planner LLM decides the goal ("book the cheapest
 * morning flight"); Jev picks the next element to act on from the live page —
 * the demo that booked a flight in ~7 seconds.
 */
export async function pickElement(goal: string, elements: PageElement[]): Promise<ElementPick> {
  if (elements.length === 0) throw new Error("No interactive elements to pick from.");
  if (elements.length > 255) throw new Error("Choice supports at most 255 options; paginate the page.");
  // Dynamic criteria: option keys are element indices, built from the live DOM at runtime.
  const criteria = Object.fromEntries(
    elements.map((el, i) => [String(i), `${el.role} labeled "${el.text}"`])
  );
  const { answers } = await jev.systemOne(
    { goal, elements },
    {
      next_action: choice("Which element in `elements` should be acted on next to advance `goal`?", criteria),
    }
  );
  const a = answers.next_action as ChoiceAnswer;
  return { selector: elements[Number(a.choice)].selector, confidence: a.confidence };
}
