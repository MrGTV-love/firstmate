/**
 * Level 10, shared: the toolkit a coding agent gets as Jev tools.
 * ask sends typed questions, buildChoiceBlock turns runtime discoveries into a validated Choice, gate maps confidence to auto, confirm, or human.
 */
import { JevClient, jev } from "../../core/client.ts";
import { choice } from "../../core/helpers.ts";
import { LIMITS, validateQuestions, type ChoiceAnswer, type Questions, type ScoreAnswer, type State } from "../../core/types.ts";

export interface ChoiceOption {
  key: string;
  description?: string;
}

export class JevToolkit {
  private client: JevClient;

  constructor(client: JevClient = jev) {
    this.client = client;
  }

  /** Tool: ask Jev anything. Typed in, typed out. */
  async ask(state: State, questions: Questions) {
    validateQuestions(questions); // fail before the wire, not after
    const { answers, usage } = await this.client.systemOne(state, questions);
    return { answers, usage };
  }

  /**
   * Tool: build a Choice block dynamically from runtime-discovered options.
   * The agent never hand-writes criteria — it passes what it found, and this
   * slugifies keys, fills descriptions, and enforces the 255-option cap.
   */
  buildChoiceBlock(instructions: string, options: (string | ChoiceOption)[]) {
    const seen = new Set<string>();
    const criteria: Record<string, string | null> = {};
    for (const opt of options) {
      const raw = typeof opt === "string" ? { key: opt } : opt;
      let key = raw.key
        .toLowerCase()
        .trim()
        .replace(/[^a-z0-9]+/g, "_")
        .replace(/^_+|_+$/g, "");
      if (!key) continue;
      let candidate = key;
      let n = 2;
      while (seen.has(candidate)) candidate = `${key}_${n++}`;
      seen.add(candidate);
      criteria[candidate] = raw.description ?? null;
      if (seen.size > LIMITS.MAX_CHOICE_OPTIONS) {
        throw new Error(
          `Dynamic choice block exceeded ${LIMITS.MAX_CHOICE_OPTIONS} options; prune in code before building.`
        );
      }
    }
    return choice(instructions, criteria);
  }

  /** Tool: gate an answer on confidence. High acts, medium confirms, low escalates. */
  gate(
    answer: ChoiceAnswer | ScoreAnswer,
    thresholds: { floor?: number; bar?: number } = {}
  ): "auto" | "confirm" | "human" {
    const floor = thresholds.floor ?? 0.5;
    const bar = thresholds.bar ?? 0.9;
    if (answer.confidence < floor) return "human";
    if (answer.confidence < bar) return "confirm";
    return "auto";
  }
}
