/**
 * Level 4, option B: shell-command gate.
 * read only, reversible, irreversible before an agent runs anything. An ambiguous rm -rf once came back irreversible at confidence 0.33, and the 0.33 is what asks the human.
 */
import { jev } from "../../core/client.ts";
import { choice, noul } from "../../core/helpers.ts";
import type { ChoiceAnswer, NoulAnswer } from "../../core/types.ts";
import { CONFIDENCE } from "./confidence.ts";

export type CommandSafety = {
  classification: "read_only" | "reversible" | "irreversible";
  run: boolean;
  requiresHuman: boolean;
  confidence: number;
};

/** B: the guardrail Flavio Copes would ship first. Classify a shell command before an agent runs it. */
export async function gateShellCommand(command: string, cwd: string): Promise<CommandSafety> {
  const { answers } = await jev.systemOne({ command, cwd }, {
    risk: choice("Classify the effect of running `command` in `cwd`.", {
      read_only: "Only reads files, state, or output; changes nothing",
      reversible: "Writes, moves, or creates, but is undoable with git or a backup",
      irreversible: "Deletes, force-pushes, rewrites history, deploys, or touches outside the repo",
    }),
    touches_outside_repo: noul("Does `command` modify anything outside `cwd`?"),
    destructive_intent: noul("Does `command` delete files, drop data, or force-push?"),
  });
  return decideCommandSafety(
    answers.risk as ChoiceAnswer,
    answers.touches_outside_repo as NoulAnswer,
    answers.destructive_intent as NoulAnswer
  );
}

export function decideCommandSafety(
  risk: ChoiceAnswer,
  touchesOutside: NoulAnswer,
  destructive: NoulAnswer
): CommandSafety {
  const classification = risk.choice as CommandSafety["classification"];
  // The famous shadow-test result: an ambiguous `rm -rf` came back
  // "irreversible" at 0.56 probability with confidence 0.33 — and the 0.33
  // is what tells the harness to ask a human. We encode exactly that.
  const requiresHuman =
    risk.confidence < CONFIDENCE.REVIEW_FLOOR ||
    (classification !== "read_only" && risk.confidence < CONFIDENCE.DESTRUCTIVE_BAR) ||
    destructive.noul > 0.6 ||
    touchesOutside.noul > 0.6;
  return {
    classification,
    run: classification === "read_only" && risk.confidence >= CONFIDENCE.REVIEW_FLOOR,
    requiresHuman,
    confidence: risk.confidence,
  };
}
