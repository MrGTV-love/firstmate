// Disposable lab driver. It runs inside the real private `dsh --profile web`
// server and calls DSH's public ctx.agents.create/resume and AgentHandle.dispose.
// Web's own controller drops its handle, so this is the supported way to reach
// true Agent termination while the server and the Firstmate plugin stay alive.
import {existsSync, readdirSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
export const name = 'fm-lab-driver';
export const inject = ['agents', 'agentDefaultModel'];
export function apply(ctx, config) {
  const handles = new Map();
  const busy = new Set();
  const options = () => {
    const {provider, model} = ctx.agentDefaultModel.currentSelection();
    return {provider, model};
  };
  const run = async ({op, id}) => {
    if (op === 'create') {
      handles.set(id, await ctx.agents.create({sessionId: id, agentOptions: options(), meta: {cwd: config.home}}));
    } else if (op === 'resume') {
      handles.set(id, await ctx.agents.resume({resumeSessionId: id, agentOptions: options()}));
    } else if (op === 'dispose') {
      const handle = handles.get(id);
      handles.delete(id);
      await handle.dispose();
    } else if (op === 'pid') {
      return {pid: process.pid};
    } else throw new Error(`unknown op ${op}`);
    return {};
  };
  const timer = setInterval(() => {
    for (const file of readdirSync(config.commands)) {
      if (!file.endsWith('.cmd') || busy.has(file)) continue;
      busy.add(file);
      const path = join(config.commands, file);
      const reply = path.replace(/\.cmd$/, '.reply');
      if (existsSync(reply)) continue;
      void (async () => {
        let result;
        try { result = {ok: true, ...(await run(JSON.parse(readFileSync(path, 'utf8'))))}; }
        catch (error) { result = {ok: false, error: String(error)}; }
        writeFileSync(`${reply}.tmp`, JSON.stringify(result));
        renameSync(`${reply}.tmp`, reply);
      })();
    }
  }, 50);
  ctx.effect(() => () => clearInterval(timer));
}
