/**
 * Level 6, option A: editor tone watch.
 * On a 600 ms typing pause: tone, urgency, reads as AI, specificity, one request. Suggestions like soften tone, never a rewrite.
 */
import { jev } from "../../core/client.ts";
import { noul, score } from "../../core/helpers.ts";
import type { NoulAnswer, ScoreAnswer } from "../../core/types.ts";

export interface EditorSignals {
  tone: number;
  urgency: number;
  readsAsAI: number;
  suggest: "none" | "soften_tone" | "add_specificity";
}

/** A: the editor demo — run on a 600ms typing pause, one request, three signals. */
export async function watchEditorTone(draft: string): Promise<EditorSignals> {
  const { answers } = await jev.systemOne({ draft }, {
    tone: score("How does `draft` read emotionally?", [
      "Neutral, factual, professional",
      "Direct or blunt, could land as sharp",
      "Hostile, insulting, sarcastic, or calls people incompetent",
    ]),
    urgency: score("How much urgency does `draft` convey?", [
      "No time pressure at all",
      "Some priority signaled",
      "Drop everything, this is on fire",
    ]),
    reads_as_ai: score("Does `draft` read as AI-written?", [
      "Human voice, specific and uneven in a natural way",
      "Generic but not obviously templated",
      "Uniform, listy, hedging — the AI register",
    ]),
    has_specifics: noul("Does `draft` contain concrete specifics: numbers, names, examples?"),
  });
  const tone = answers.tone as ScoreAnswer;
  const urgency = answers.urgency as ScoreAnswer;
  const readsAsAI = answers.reads_as_ai as ScoreAnswer;
  const hasSpecifics = answers.has_specifics as NoulAnswer;
  let suggest: EditorSignals["suggest"] = "none";
  if (tone.score > 1.2) suggest = "soften_tone";
  else if (hasSpecifics.noul < 0.4) suggest = "add_specificity";
  return {
    tone: tone.score,
    urgency: urgency.score,
    readsAsAI: readsAsAI.score,
    suggest,
  };
}
