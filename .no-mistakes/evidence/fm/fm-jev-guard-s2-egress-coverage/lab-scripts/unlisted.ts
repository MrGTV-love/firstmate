// A lab-only extension tool that has no TOOL_POLICY row.
export default function (pi: any) {
  pi.registerTool({ name: "fm_lab_unlisted", label: "lab", description: "Lab tool with no policy row.",
    parameters: { type: "object", properties: { note: { type: "string" } } },
    async execute() { require("node:fs").writeFileSync(process.env.FM_LAB_UNLISTED_MARK!, "ran"); return { content: [{ type: "text", text: "unlisted-ran" }] }; } });
}
