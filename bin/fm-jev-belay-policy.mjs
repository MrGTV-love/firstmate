import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const library = fileURLToPath(new URL('./fm-typesafe-lib.sh', import.meta.url));
const policy = resolve(process.env.FM_CONFIG_OVERRIDE || resolve(process.env.FM_HOME, 'config'), 'dispatch-never-send');
const transport = globalThis.fetch;

globalThis.fetch = async (url, options) => {
  if (typeof options?.body !== 'string') throw new Error('jev-belay request withheld');
  const env = { ...process.env };
  delete env.TYPESAFE_API_KEY;
  delete env.TYPESAFE_API_KEY_PRIVATE;
  const checked = spawnSync('bash', ['-c', `
    . "$1" || exit 1
    scratch=$(mktemp "\${TMPDIR:-/tmp}/fm-belay-policy.XXXXXX") || exit 1
    trap 'rm -f "$scratch"' EXIT
    request=$(cat) || exit 1
    fm_typesafe_permitted "$request" "$2" "$scratch"
  `, '_', library, policy], {
    input: options.body,
    env,
    stdio: ['pipe', 'ignore', 'ignore'],
  });
  if (checked.status !== 0) throw new Error('jev-belay request withheld');
  return transport(url, options);
};