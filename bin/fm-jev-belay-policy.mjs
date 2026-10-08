import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const library = fileURLToPath(new URL('./fm-typesafe-lib.sh', import.meta.url));
const timeoutLibrary = fileURLToPath(new URL('./fm-timeout-lib.sh', import.meta.url));
const policy = resolve(process.env.FM_CONFIG_OVERRIDE || resolve(process.env.FM_HOME, 'config'), 'dispatch-never-send');
const transport = globalThis.fetch;

globalThis.fetch = async (url, options) => {
  if (typeof options?.body !== 'string') throw new Error('jev-belay request withheld');
  const env = { ...process.env };
  delete env.TYPESAFE_API_KEY;
  delete env.TYPESAFE_API_KEY_PRIVATE;
  const checked = spawnSync('bash', ['-c', `
    . "$3" || exit 1
    check_request() {
      . "$1" || exit 1
      scratch=$(mktemp "\${TMPDIR:-/tmp}/fm-belay-policy.XXXXXX") || exit 1
      trap 'rm -f "$scratch"' EXIT
      request=$(cat <&3) || exit 1
      fm_typesafe_permitted "$request" "$2" "$scratch"
    }
    FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed 3 check_request "$1" "$2" 3<&0
  `, '_', library, policy, timeoutLibrary], {
    input: options.body,
    env,
    stdio: ['pipe', 'ignore', 'ignore'],
    // Leave startup and cleanup headroom around the process-group deadline.
    timeout: 5000,
    killSignal: 'SIGKILL',
  });
  if (checked.status !== 0) throw new Error('jev-belay request withheld');
  return transport(url, options);
};