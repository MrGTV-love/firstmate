"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.FIRSTMATE_CURRENT_OPERATIONAL_KINDS = void 0;exports.classifyFirstmateCurrentOperationalText = classifyFirstmateCurrentOperationalText;exports.classifyFirstmateOperationalText = classifyFirstmateOperationalText;exports.encodeFirstmateOperationalInput = encodeFirstmateOperationalInput;exports.encodeFirstmateOperationalInputWith = encodeFirstmateOperationalInputWith;exports.firstmateShellInvocation = firstmateShellInvocation;exports.isFirstmateOperationalPresentationText = isFirstmateOperationalPresentationText;var _nodeChild_process = await jitiImport("node:child_process");
var _nodePath = await jitiImport("node:path");
var _nodeUrl = await jitiImport("node:url");

const operationalInputScript =
process.env.FM_OPERATIONAL_INPUT_SCRIPT ||
(0, _nodePath.resolve)((0, _nodePath.dirname)((0, _nodeUrl.fileURLToPath)("file:///Users/charlesabrooker/tmp/fm-pi-render-drift-main016.mYxnxr/nm/worktrees/c6711555e1ec/01M445ME32DXNHDANAED5TJK7X/fm-calm-pi-extension.TCmxHS/e2e-project/.pi/extensions/lib/fm-operational-input.ts")), "../../../bin/fm-operational-input.sh");

const FIRSTMATE_CURRENT_OPERATIONAL_KINDS = exports.FIRSTMATE_CURRENT_OPERATIONAL_KINDS = [
"session-start",
"watcher",
"turn-end-guard",
"away-supervisor",
"from-firstmate",
"launch-brief",
"branch-outcome"];







function firstmateShellInvocation(
script,
args)
{
  return process.platform === "win32" ?
  { command: "bash", args: [script, ...args] } :
  { command: script, args: [...args] };
}

// The one owner of how each command is invoked and how its exit status and
// stdout become an answer, shared by the synchronous and awaited callers
// below so the two can never drift.
function operationalInputArgs(
command,
kind)
{
  return command === "encode" ? [command, kind ?? ""] : [command];
}

function operationalInputAnswer(
command,
status,
stdout)
{
  if (status !== 0) return undefined;
  return command === "classify" ? stdout.replace(/\n$/, "") : stdout;
}

function runOperationalInputCommand(
command,
content,
kind)
{
  const invocation = firstmateShellInvocation(
    operationalInputScript,
    operationalInputArgs(command, kind)
  );
  try {
    const result = (0, _nodeChild_process.spawnSync)(invocation.command, invocation.args, {
      encoding: "utf8",
      input: content,
      maxBuffer: 1024 * 1024
    });
    return operationalInputAnswer(command, result.status, result.stdout ?? "");
  } catch {
    return undefined;
  }
}

function encodeFailure(kind) {
  return new Error(`could not encode Firstmate operational input kind ${kind}`);
}

function encodeFirstmateOperationalInput(
kind,
content)
{
  const encoded = runOperationalInputCommand("encode", content, kind);
  if (encoded === undefined) throw encodeFailure(kind);
  return encoded;
}

// The supervision branch encodes on Pi's render thread while a captain
// outcome is being delivered, so that one caller must await the child rather
// than stop the TUI for it. It supplies the wait; everything that makes this
// an encode - the script, its argument shape, and how its exit status and
// stdout become an answer - stays owned here, so the two forms cannot drift.
// The runner is a parameter rather than an import so that every extension
// already carrying this module does not also have to carry a spawn helper it
// never calls.






async function encodeFirstmateOperationalInputWith(
run,
kind,
content)
{
  const invocation = firstmateShellInvocation(
    operationalInputScript,
    operationalInputArgs("encode", kind)
  );
  const result = await run(invocation.command, invocation.args, { input: content });
  const encoded = operationalInputAnswer("encode", result.status, result.stdout);
  if (encoded === undefined) throw encodeFailure(kind);
  return encoded;
}

function classifyFirstmateOperationalText(content) {
  return runOperationalInputCommand("classify", content);
}

function classifyFirstmateCurrentOperationalText(
content)
{
  return runOperationalInputCommand("kind", content);
}

// The only legacy operational shape Calm presentation hides on top of the current
// typed kinds. The broader `classify` legacy set stays out: its bare forms are text a
// captain can type, so hiding them would hide real input.
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

// Single owner of "may Calm presentation hide this exact input?", shared by the
// transcript-row and queued-row adapters so the two can never disagree about a message.
// Text without the U+2063 marker answers here without spawning the classifier.
function isFirstmateOperationalPresentationText(text) {
  if (!text.includes("\u2063")) return false;
  return (
    classifyFirstmateCurrentOperationalText(text) !== undefined ||
    text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX));

} /* v9-4ea5982f0fa24797 */
