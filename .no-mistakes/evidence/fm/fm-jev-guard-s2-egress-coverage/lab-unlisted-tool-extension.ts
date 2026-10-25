// Disposable lab-only extension: registers one tool that has no TOOL_POLICY row.
export default function (pi: any) {
  pi.registerTool({ name: "fm_t4_unlisted_probe", label: "probe", description: "Lab probe tool with no table row.",
    parameters: { type: "object", properties: { i: { type: "string" } }, required: [] },
    async execute() { require("node:fs").writeFileSync(process.env.FM_T4_PROBE_MARK!, "ran"); return { content: [{ type: "text", text: "probe-ran" }] }; } });
}
