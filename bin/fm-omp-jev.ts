// Native omp judge credentials are resolved privately by its supported !command
// provider API. Only code/home paths enter configuration and argv, never a key.
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

interface ProviderRegistration {
  registerProvider(provider: string, config: { apiKey: string; baseUrl: string }): void;
}

const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;

export function installTypesafeJudge(pi: ProviderRegistration, home: string, noHelpers = false) {
  const lib = resolve(dirname(fileURLToPath(import.meta.url)), "fm-typesafe-lib.sh");
  const lookup = '. "$1"; fm_typesafe_key "$2" && printf %s "$TYPESAFE_API_KEY_PRIVATE"';
  // omp executes this on credential lookup and memoizes successful results for
  // the process. Its private stdout pipe does not become the worker environment.
  const apiKey = noHelpers ? "!false" : `!bash -c ${quote(lookup)} _ ${quote(lib)} ${quote(home)} 2>/dev/null`;
  const baseUrl = process.env.FM_TEST_SEAM === "1" && process.env.FM_OMP_JEV_BASE_URL
    ? process.env.FM_OMP_JEV_BASE_URL : "https://api.typesafe.ai";
  pi.registerProvider("typesafe", { apiKey, baseUrl });
}
