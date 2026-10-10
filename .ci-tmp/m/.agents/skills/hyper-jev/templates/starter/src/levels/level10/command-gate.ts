/**
 * Level 10, option A: the agent gates its own command.
 * The agent reads the command, detects a force-push, adds options that exist only for this command, sends one call, and escalates on confidence.
 */
import { choice, noul } from "../../core/helpers.ts";
import type { ChoiceAnswer, NoulAnswer } from "../../core/types.ts";
import { JevToolkit, type ChoiceOption } from "./toolkit.ts";

/** Effect signals the agent detects in a command — it turns findings into options. */
const COMMAND_SIGNALS: { pattern: RegExp; option: ChoiceOption }[] = [
  { pattern: /\bgit\s+push\b/, option: { key: "pushes_commits", description: "Pushes commits to a remote" } },
  { pattern: /\bgit\s+(reset|checkout|rebase)\b|--force/, option: { key: "rewrites_git_history", description: "Rewrites or force-overwrites git history" } },
  { pattern: /\brm\b|rmdir|unlink/, option: { key: "deletes_files", description: "Deletes files or directories" } },
  { pattern: /\b(curl|wget|ssh|scp)\b|https?:\/\//, option: { key: "network_access", description: "Reaches out to the network" } },
  { pattern: /\b(npm|pnpm|yarn|pip|cargo)\s+(i|install|add)\b/, option: { key: "installs_packages", description: "Installs third-party packages" } },
  { pattern: /\b(docker|kubectl|terraform)\b/, option: { key: "touches_infrastructure", description: "Builds, deploys, or mutates infrastructure" } },
  { pattern: /(^|\s|;|&&)\s*(cat|ls|grep|rg|head|tail|wc|find|git\s+(status|log|diff))\b/, option: { key: "pure_read", description: "Only reads files or status" } },
];

/** The agent reads the command and derives the option set for this specific call. */
export function buildCommandChoiceBlock(command: string, cwd: string) {
  const toolkit = new JevToolkit();
  const discovered = COMMAND_SIGNALS.filter((s) => s.pattern.test(command)).map((s) => s.option);
  // The rubric baseline plus everything the agent detected in THIS command.
  const options: (string | ChoiceOption)[] = [
    { key: "read_only", description: "Changes nothing; safe to run unattended" },
    { key: "reversible", description: "Changes state but is recoverable via git or backups" },
    { key: "irreversible", description: "Deletes, force-pushes, or deploys; cannot be undone cheaply" },
    ...discovered, // dynamic options — different for every command
  ];
  const question = toolkit.buildChoiceBlock(
    "Classify the effect of running `command` in `cwd`, considering the detected behaviors.",
    options
  );
  return { question, detected: discovered.map((d) => d.key) };
}

export type AgentGate = {
  run: boolean;
  requiresConfirmation: boolean;
  classification: string;
  detected: string[];
  confidence: number;
  gate: "auto" | "confirm" | "human";
};

/** Options that mean "no state changes anywhere". The safe set lives next to the rubric it refers to. */
const SAFE_CLASSIFICATIONS = new Set(["read_only", "pure_read"]);

/** The full loop: agent builds the block, asks Jev, gates the answer, decides.
 *  The detected behaviors ride along in the state as evidence for the block it just authored. */
export async function gateAgentCommand(command: string, cwd: string): Promise<AgentGate> {
  const toolkit = new JevToolkit();
  const { question, detected } = buildCommandChoiceBlock(command, cwd);
  const { answers } = await toolkit.ask(
    { command, cwd, detected_behaviors: detected.map((d) => d.replace(/_/g, " ")) },
    {
      risk: question,
      ambiguous: noul("Is the effect unclear from the text alone?", {
        true: "The command's purpose or effect is genuinely unclear",
        false: "The effect is clear: a well-known read, status check, or push",
      }),
    }
  );
  const risk = answers.risk as ChoiceAnswer;
  const ambiguous = (answers.ambiguous as NoulAnswer).noul > 0.5;
  // Resolve escalation before computing every execution-related field.
  const gate = ambiguous ? "human" : toolkit.gate(risk, { floor: 0.5, bar: 0.9 });
  return {
    run: gate === "auto" && SAFE_CLASSIFICATIONS.has(risk.choice),
    requiresConfirmation: gate !== "auto" || !SAFE_CLASSIFICATIONS.has(risk.choice),
    classification: risk.choice,
    detected,
    confidence: risk.confidence,
    gate,
  };
}
