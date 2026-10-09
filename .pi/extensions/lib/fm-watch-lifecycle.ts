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
// with -e, or rebound by a reload). Each factory bind claims the home's slot in
// a process-global registry, so the latest bind is the current instance and
// every earlier one learns it was superseded. Each extension decides what a
// superseded instance does; the registry only answers who is current.
import { appendFileSync, mkdirSync, renameSync, statSync } from "node:fs";
import { dirname } from "node:path";

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
type WatchInstanceRegistry = { nextId: number; slots: Map<string, WatchInstanceSlot<unknown>> };

export type WatchInstanceBinding<T> = {
  id: number;
  previous: WatchInstanceSlot<T> | null;
  isCurrent: () => boolean;
  current: () => WatchInstanceSlot<T> | null;
  publish: (api: T) => void;
};

// Claim <home>'s slot in the process-global registry named <registryKey>.
export function bindWatchInstance<T>(registryKey: string, home: string): WatchInstanceBinding<T> {
  const holder = globalThis as typeof globalThis & Record<string, WatchInstanceRegistry | undefined>;
  const registry = holder[registryKey] ??= { nextId: 0, slots: new Map() };
  const previous = (registry.slots.get(home) as WatchInstanceSlot<T> | undefined) ?? null;
  const slot: WatchInstanceSlot<T> = { id: ++registry.nextId, api: null };
  registry.slots.set(home, slot as WatchInstanceSlot<unknown>);
  return {
    id: slot.id,
    previous,
    isCurrent: () => registry.slots.get(home) === slot,
    current: () => (registry.slots.get(home) as WatchInstanceSlot<T> | undefined) ?? null,
    publish: (api: T) => {
      slot.api = api;
    },
  };
}
