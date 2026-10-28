// Shared session-lifecycle evidence and single-instance ownership for the
// primary watcher extensions (.pi/extensions/fm-primary-pi-watch.ts and
// .omp/extensions/fm-primary-omp-watch.ts).
//
// Lifecycle evidence: session events, factory binds, generation transitions,
// and recovery attempts use one line per event:
//   <ISO time> pid=<pid> instance=<n> event=<name> [key=value...]
// at state/extensions/<extension>/lifecycle.log. Before the next append at
// 256 KiB, rotate to lifecycle.log.1, replacing the previous rotation. Expired
// bounds use waiter, waited-on, bound, and actual fields. This record is
// best-effort and never throws: evidence failure must not break supervision.
//
// Single instance: one process may evaluate a watcher extension more than
// once for the same home (for example when it is both auto-discovered and named
// with -e, when a helper session loads it, or when a reload rebinds it). Each
// factory bind claims the home's slot in a process-global registry, so the
// latest bind is the current instance and every earlier one learns it was
// superseded. The registry answers who is current, can hand the slot back
// (claim), and can name the newest other instance that is still live (earlier);
// each extension decides what a superseded instance does and what live means.
// A binding's previous slot is only for transferring predecessor state. Callers
// release it after handoff; publish also clears it before storing an API that
// may capture the binding, so the current slot cannot retain retired factories
// through a chain of predecessor APIs.
import { appendFileSync, mkdirSync, renameSync, statSync } from "node:fs";
import { dirname } from "node:path";
import { performance } from "node:perf_hooks";

// Timer callbacks can arrive before their nominal delay. Expire only after the
// monotonic deadline, and retain measured elapsed time for lifecycle evidence.
export function setLifecycleDeadline(callback: () => void, boundMs: number) {
  const startedAt = performance.now();
  let unreferenced = false;
  let timer: ReturnType<typeof setTimeout>;
  function expire(): void {
    const remaining = boundMs - (performance.now() - startedAt);
    if (remaining > 0) {
      timer = setTimeout(expire, Math.ceil(remaining));
      if (unreferenced) timer.unref();
      return;
    }
    callback();
  }
  timer = setTimeout(expire, boundMs);
  return {
    elapsedMs: () => Math.floor(performance.now() - startedAt),
    cancel: () => clearTimeout(timer),
    unref: () => {
      unreferenced = true;
      timer.unref();
    },
  };
}

export type LifecycleFields = Record<string, string | number | boolean | null | undefined>;
export type LifecycleLog = (event: string, fields?: LifecycleFields) => void;

const lifecycleMaxBytes = 256 * 1024;

export function createLifecycleLog(path: string, instance: () => number): LifecycleLog {
  return (event, fields = {}) => {
    try {
      mkdirSync(dirname(path), { recursive: true });
      try {
        if (statSync(path).size >= lifecycleMaxBytes) renameSync(path, `${path}.1`);
      } catch {
        // Absent: nothing to rotate.
      }
      const parts = [new Date().toISOString(), `pid=${process.pid}`, `instance=${instance()}`, `event=${event}`];
      for (const [key, value] of Object.entries(fields)) {
        if (value === undefined || value === null || value === "") continue;
        parts.push(`${key}=${String(value).replace(/\s+/g, "_")}`);
      }
      appendFileSync(path, `${parts.join(" ")}\n`);
    } catch {
      // The record is evidence only; supervision continues without it.
    }
  };
}

export type WatchInstanceSlot<T> = { id: number; api: T | null };
type WatchInstanceRegistry = {
  nextId: number;
  slots: Map<string, WatchInstanceSlot<unknown>>;
  // Every bind per home, held weakly: an instance whose session is gone is
  // collected and drops out, while a session that still lives keeps its own
  // slot reachable through its tools. Used only to find a live earlier owner.
  history: Map<string, WeakRef<WatchInstanceSlot<unknown>>[]>;
};

export type WatchInstanceBinding<T> = {
  id: number;
  previous: WatchInstanceSlot<T> | null;
  isCurrent: () => boolean;
  current: () => WatchInstanceSlot<T> | null;
  publish: (api: T) => void;
  // Take the home's slot back from whichever instance holds it and return that
  // displaced slot (null when this instance already held it).
  claim: () => WatchInstanceSlot<T> | null;
  // The newest other instance whose session is still live, by the owner's own
  // liveness answer. A dead or ended instance is never returned.
  earlier: (isLive: (api: T) => boolean) => WatchInstanceSlot<T> | null;
};

// Claim <home>'s slot in the process-global registry named <registryKey>.
export function bindWatchInstance<T>(registryKey: string, home: string): WatchInstanceBinding<T> {
  const holder = globalThis as typeof globalThis & Record<string, WatchInstanceRegistry | undefined>;
  const registry = holder[registryKey] ??= { nextId: 0, slots: new Map(), history: new Map() };
  const slot: WatchInstanceSlot<T> = { id: ++registry.nextId, api: null };
  const history = (registry.history.get(home) ?? []).filter((ref) => ref.deref() !== undefined);
  history.push(new WeakRef(slot as WatchInstanceSlot<unknown>));
  registry.history.set(home, history);
  const binding: WatchInstanceBinding<T> = {
    id: slot.id,
    previous: (registry.slots.get(home) as WatchInstanceSlot<T> | undefined) ?? null,
    isCurrent: () => registry.slots.get(home) === slot,
    current: () => (registry.slots.get(home) as WatchInstanceSlot<T> | undefined) ?? null,
    publish: (api: T) => {
      binding.previous = null;
      slot.api = api;
    },
    claim: () => {
      const displaced = (registry.slots.get(home) as WatchInstanceSlot<T> | undefined) ?? null;
      registry.slots.set(home, slot as WatchInstanceSlot<unknown>);
      return displaced === slot ? null : displaced;
    },
    earlier: (isLive) => {
      const refs = registry.history.get(home) ?? [];
      for (let index = refs.length - 1; index >= 0; index -= 1) {
        const other = refs[index].deref() as WatchInstanceSlot<T> | undefined;
        if (other && other !== slot && other.api && isLive(other.api)) return other;
      }
      return null;
    },
  };
  registry.slots.set(home, slot as WatchInstanceSlot<unknown>);
  return binding;
}
