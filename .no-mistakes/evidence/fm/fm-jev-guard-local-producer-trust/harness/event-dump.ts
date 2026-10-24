// Records the exact native tool_result event omp hands to extensions (read-only observer).
import { appendFileSync } from "node:fs";
export default function (pi: any) {
  pi.on("tool_result", (event: any) => {
    appendFileSync(`${process.env.FM_LAB}/events.jsonl`, JSON.stringify({ toolName: event.toolName, input: event.input,
      content: event.content, details: event.details, isError: event.isError }) + "\n");
    return undefined;
  });
}
