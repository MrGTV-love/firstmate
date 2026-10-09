
import { appendFileSync, existsSync } from "node:fs";
const first = !existsSync(process.env.FM_ARM_LOG);
process.on("SIGTERM", () => {});
appendFileSync(process.env.FM_ARM_LOG, process.pid + "\n");
if (first) {
  console.log("watcher: started pid=" + process.pid + " (beacon fresh)");
  if (process.env.FM_EXPIRY_SCENARIO !== "shutdown") {
    console.log("signal: expiry regression wake");
    process.exit(0);
  }
}
setInterval(() => {}, 1000);
