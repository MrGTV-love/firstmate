// Native omp judge credentials are resolved privately by its supported !command
// provider API. Only code/home paths enter configuration and argv, never a key.
// bin/fm-spawn.sh's header owns native judge credential eligibility.
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

interface ProviderRegistration {
  registerProvider(provider: string, config: { apiKey: string; baseUrl: string }): void;
}

const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;

export function installTypesafeJudge(pi: ProviderRegistration, context: { home: string; project?: string; noHelpers?: boolean }) {
  const lib = resolve(dirname(fileURLToPath(import.meta.url)), "fm-typesafe-lib.sh");
  const lookup = '. "$1"; fm_typesafe_key "$2" && printf %s "$TYPESAFE_API_KEY_PRIVATE"';
  const authorized = context.project === "firstmate" && context.noHelpers !== true;
  // omp executes this on credential lookup and memoizes successful results for
  // the process. Its private stdout pipe does not become the worker environment.
  const apiKey = authorized ? `!bash -c ${quote(lookup)} _ ${quote(lib)} ${quote(context.home)} 2>/dev/null` : "!false";
  pi.registerProvider("typesafe", { apiKey, baseUrl: "https://api.typesafe.ai" });
}
