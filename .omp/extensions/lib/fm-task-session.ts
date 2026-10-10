// Current-session proof for managed omp tasks. All writes are synchronous so
// lifecycle observers cannot see the previous session after a switch completes.
import { spawnSync } from "node:child_process";
import { closeSync, existsSync, openSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, resolve } from "node:path";

type Context = { sessionManager?: { getSessionFile?: () => string | undefined }; ui?: { notify?: (message: string, level: string) => void } };
type Proof = { version: 1; spawn_gen: string; pid: number; task_session_file: string; current_session_file: string };
type SessionOwner = { sessionManager: Context["sessionManager"]; waitForSessionTransition: () => Promise<void> };
type Registry = { list: () => { kind: string; session: SessionOwner | null }[] };
type API = { pi: { AgentRegistry: { global: () => Registry } }; on?: (event: string, handler: (event: unknown, ctx: Context) => void) => void };

// Use the existing identity/parent parser, not an environment-supplied task id.
// Remote secondmates and main homes have no local parent task proof to publish.
export function resolveLocalSecondmateTask(fmRoot: string, home: string, state: string): { state: string; id: string } | null {
  if (!existsSync(resolve(home, ".fm-secondmate-home"))) return null;
  const result = spawnSync("bash", ["-c", '. "$1"; destination=$(fm_parent_channel_destination "$2" "$3") || exit $?; fm_secondmate_parent_record_parse "$2/.fm-secondmate-parent" || exit 3; [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || exit 1; printf "%s" "$destination"', "fm-task-session", resolve(fmRoot, "bin/fm-parent-channel-lib.sh"), home, state], { encoding: "utf8" });
  if (result.status !== 0) {
    if (result.status !== 1) console.warn("firstmate: omp task-session proof unavailable: invalid secondmate parent binding");
    return null;
  }
  const destination = result.stdout;
  if (!isAbsolute(destination) || /[\r\n\0]/.test(destination) || !destination.endsWith(".status")) {
    console.warn("firstmate: omp task-session proof unavailable: invalid parent destination");
    return null;
  }
  const id = destination.slice(destination.lastIndexOf("/") + 1, -7);
  if (!/^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(id)) return null;
  return { state: dirname(destination), id };
}

export function createTaskSessionProof(state: string, id: string, registry: Registry): { start: (ctx: Context) => void; shutdown: (ctx: Context) => void; before: (ctx: Context) => void } {
  if (!/^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(id)) throw new Error("invalid omp task-session id");
  const path = resolve(state, `${id}.omp-session.json`);
  const meta = resolve(state, `${id}.meta`);
  const gen = process.env.FM_SPAWN_GEN || "";
  let serial = 0;
  let revision = 0;
  const warn = (error: unknown, ctx?: Context) => {
    const message = `firstmate: omp task-session proof unavailable: ${error instanceof Error ? error.message : String(error)}`;
    console.warn(message);
    ctx?.ui?.notify?.(message, "warning");
  };
  function matchesMetadata(): boolean {
    if (!gen || /[\r\n\0]/.test(gen)) return false;
    const values = readFileSync(meta, "utf8").split(/\r?\n/).filter(line => line.startsWith("spawn_gen="));
    return values.length === 1 && values[0] === `spawn_gen=${gen}`;
  }
  function previous(): Proof | null {
    let text: string;
    try { text = readFileSync(path, "utf8"); } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw error;
    }
    const value = JSON.parse(text);
    if (value?.version !== 1 || typeof value.spawn_gen !== "string" || !Number.isSafeInteger(value.pid) || value.pid <= 0 || typeof value.task_session_file !== "string" || !isAbsolute(value.task_session_file) || typeof value.current_session_file !== "string" || (value.current_session_file !== "" && !isAbsolute(value.current_session_file))) throw new Error("invalid existing session proof; refusing to rebind task session");
    return value;
  }
  function publish(value: Proof): void {
    const temporary = `${path}.${process.pid}.${++serial}.tmp`;
    let fd: number | undefined;
    try {
      fd = openSync(temporary, "wx", 0o600);
      writeFileSync(fd, `${JSON.stringify(value)}\n`);
      closeSync(fd);
      fd = undefined;
      if (!matchesMetadata()) throw new Error("spawn generation no longer matches metadata");
      renameSync(temporary, path);
    } finally {
      if (fd !== undefined) closeSync(fd);
      if (existsSync(temporary)) unlinkSync(temporary);
    }
  }
  function invalidate(): void {
    if (!matchesMetadata()) return;
    const old = previous();
    if (old?.spawn_gen === gen && old.pid === process.pid) publish({ ...old, current_session_file: "" });
  }
  function owner(ctx: Context) {
    if (!ctx.sessionManager) return undefined;
    let match;
    for (const ref of registry.list()) {
      if (!ref.session || ref.session.sessionManager !== ctx.sessionManager) continue;
      if (match) return undefined;
      match = ref;
    }
    return match?.kind === "main" ? match.session : undefined;
  }
  function sessionFile(ctx: Context): string {
    const file = ctx?.sessionManager?.getSessionFile?.();
    if (!file || !isAbsolute(file)) throw new Error("active session file is missing or ambiguous");
    try { return realpathSync(file); } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      return resolve(realpathSync(dirname(file)), basename(file));
    }
  }
  const proof = {
    start(ctx: Context) {
      if (!gen || !owner(ctx)) return;
      try {
        if (!matchesMetadata()) throw new Error("spawn generation does not match metadata");
        const old = previous();
        const current = sessionFile(ctx);
        publish({ version: 1, spawn_gen: gen, pid: process.pid, task_session_file: old?.spawn_gen === gen ? old.task_session_file : current, current_session_file: current });
      } catch (error) {
        // A failed switch must never leave the previous active session proven.
        try { invalidate(); } catch (failure) {
          warn(failure, ctx);
          // If even invalidation fails, remove only this process's proof.
          // Propagate the failure so omp cannot silently finish the switch.
          try {
            const old = previous();
            if (matchesMetadata() && old?.spawn_gen === gen && old.pid === process.pid) unlinkSync(path);
          } catch { /* An unreadable/corrupt record is already unusable proof. */ }
        }
        warn(error, ctx);
        throw error;
      }
    },
    shutdown(ctx: Context) {
      if (!gen || !owner(ctx)) return;
      revision++;
      try { invalidate(); } catch (error) {
        try {
          const old = previous();
          if (matchesMetadata() && old?.spawn_gen === gen && old.pid === process.pid) unlinkSync(path);
        } catch { /* Fail closed on unusable proof. */ }
        warn(error, ctx);
        throw error;
      }
    },
    before(ctx: Context) {
      if (!gen) return;
      const session = owner(ctx);
      if (!session) return;
      const old = previous();
      proof.shutdown(ctx);
      const pending = revision;
      void session.waitForSessionTransition().then(() => {
        if (owner(ctx) !== session || revision !== pending || !old?.current_session_file || old.spawn_gen !== gen || old.pid !== process.pid || !matchesMetadata()) return;
        const active = previous();
        if (active?.spawn_gen === gen && active.pid === process.pid && active.task_session_file === old.task_session_file && active.current_session_file !== old.current_session_file && sessionFile(ctx) === old.current_session_file) publish(old);
      }).catch(error => warn(error, ctx));
    },
  };
  return proof;
}

export function installTaskSessionProof(pi: API, state: string, id: string): void {
  // The extension API exposes the host SDK, including its live registry, even
  // in compiled omp executables with no separately resolvable package.
  const proof = createTaskSessionProof(state, id, pi.pi.AgentRegistry.global());
  // omp 18.8.1 /resume emits before_switch/switch, not shutdown/start.
  // Before-events invalidate while ctx still names the predecessor; after-
  // events synchronously publish the activated file before lifecycle readers.
  for (const event of ["session_start", "session_switch", "session_branch"]) {
    pi.on?.(event, (_event, ctx) => proof.start(ctx));
  }
  pi.on?.("session_shutdown", (_event, ctx) => proof.shutdown(ctx));
  for (const event of ["session_before_switch", "session_before_branch"]) {
    pi.on?.(event, (_event, ctx) => proof.before(ctx));
  }
}
