/**
 * Level 6 extension: guardrail hooks. The agent never knows Jev is here.
 *
 *   tool_call    bash: gateBashCommand, block irreversible or destructive commands
 *                write, edit: gateWriteCall, block paths outside the repo (code) and credentials (Jev)
 *   tool_result  read, bash: screenToolResult, prepend a banner when the output carries instructions
 *
 * Every decision is reported on the side channel so the lab window shows it as it happens.
 * Load: pi -e extensions/jev-guard.ts --tools read,bash,edit,write
 */
import { decide, levelConfig, report } from "./report.ts";
import { BLOCK_NOTICE, gateBashCommand, gateWriteCall, screenToolResult } from "../src/levels/level06/index.ts";

type Option = "A" | "B" | "C";

export default function (pi: any) {
  const cfg = levelConfig<{ gates: Option[] }>({ gates: ["A", "B", "C"] });
  const on = (o: Option) => cfg.gates.includes(o);

  pi.on("tool_call", async (event: any, ctx: any) => {
    try {
      if (event.toolName === "bash" && on("A")) {
        const command = String(event.input?.command ?? "");
        const d = await gateBashCommand(command, ctx.cwd, (s, q) => decide(pi, "tool_call bash", s, q));
        report(pi, "hook", { hook: "tool_call", tool: "bash", command, block: d.block, reason: d.reason });
        if (d.block) return { block: true, reason: `jev-guard blocked this command: ${d.reason}. ${BLOCK_NOTICE}` };
      }
      if ((event.toolName === "write" || event.toolName === "edit") && on("B")) {
        const path = String(event.input?.path ?? "");
        const content = String(event.input?.content ?? event.input?.newText ?? event.input?.new_string ?? "");
        const d = await gateWriteCall(path, content, ctx.cwd, (s, q) => decide(pi, `tool_call ${event.toolName}`, s, q));
        report(pi, "hook", { hook: "tool_call", tool: event.toolName, path, block: d.block, reason: d.reason });
        if (d.block) return { block: true, reason: `jev-guard blocked this ${event.toolName}: ${d.reason}. ${BLOCK_NOTICE}` };
      }
    } catch (err: any) {
      report(pi, "error", { hook: "tool_call", message: err?.message ?? String(err) });
    }
  });

  pi.on("tool_result", async (event: any) => {
    if (!on("C") || !(event.toolName === "read" || event.toolName === "bash")) return;
    try {
      const text = Array.isArray(event.content) ? event.content.filter((c: any) => c?.type === "text").map((c: any) => c.text).join("\n") : "";
      const d = await screenToolResult(event.toolName, text, (s, q) => decide(pi, `tool_result ${event.toolName}`, s, q));
      report(pi, "hook", { hook: "tool_result", tool: event.toolName, flag: d.flag, noul: d.noul, banner: d.banner });
      if (d.flag && d.banner) {
        return { content: [{ type: "text", text: `${d.banner}\n\n${text}` }] };
      }
    } catch (err: any) {
      report(pi, "error", { hook: "tool_result", message: err?.message ?? String(err) });
    }
  });
}
