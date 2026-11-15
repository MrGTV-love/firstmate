#!/usr/bin/env node
// fm-tasks-axi-locked-unblock.mjs - the finished-blocker clear after a typed public-followup
// completion, decided and written under tasks-axi's own store lock (Main 1873, 1882).
//
// Usage: node bin/fm-tasks-axi-locked-unblock.mjs <tasks-axi-package-dir> <root> <file> <id>
//
// tasks-axi 0.2.6 has no command that reads a blocker's state and removes its dependents'
// blocked-by edges in one store transaction: `unblock` removes one edge under the lock and never
// looks at the blocker (dist/src/commands/state.js:344-356, dist/src/backends/markdown.js:867-883).
// Its store lock is exported, though, and every tasks-axi write takes it: withLock(path)
// (dist/src/backends/lock.js:127-134) holds `<backlog path>.lock` (lock.js:94-95). This helper
// opens the store exactly as the CLI does (dist/src/context.js:4-18 resolveTasksContext, with the
// CLI's working directory and --file), then, inside one withLock(store.path), loads the backlog
// (MarkdownStore loadForUpdate, markdown.js:231-234), decides from it and writes the edge changes
// with persist (markdown.js:345-348, which also refuses a file changed on disk). The store
// methods it calls are not a public tasks-axi API (the package has no exports map), so it is
// pinned (Main 1890): it refuses, changing nothing, unless the package is tasks-axi at exactly
// the version it was checked against (CHECKED_VERSION) and its modules load with these
// functions.
//
// Inside the lock: when an item with <id> is in the active backlog and is not done, nothing is
// changed and the first line is `keep <state>`. Otherwise (no such item, or it is done) every
// other item's `blocked-by: <id>` edge is removed in one write, and the first line is `clear`,
// then one `unblocked <dependent> <remaining blocked-by ids, comma separated, or ->` line each.
// Any failure (package, backend, lock, read, write) changes nothing, prints the reason on
// standard error and exits 1.
import { pathToFileURL } from "node:url";
import { join } from "node:path";
import { readFileSync } from "node:fs";

export const CHECKED_VERSION = "0.2.6";

export async function lockedUnblock({ pkg, root, file, id, inside }) {
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(join(pkg, "package.json"), "utf8"));
  } catch (error) {
    throw new Error(`the tasks-axi package manifest at ${pkg} cannot be read`);
  }
  if (manifest.name !== "tasks-axi" || manifest.version !== CHECKED_VERSION) {
    throw new Error(`the package at ${pkg} is ${manifest.name} ${manifest.version}, not tasks-axi ${CHECKED_VERSION}, the version this clear was checked against`);
  }
  const load = async (rel) => {
    try {
      return await import(pathToFileURL(join(pkg, "dist", "src", rel)).href);
    } catch (error) {
      throw new Error(`the tasks-axi module ${rel} cannot be loaded`);
    }
  };
  const { resolveTasksContext } = await load("context.js");
  const { withLock } = await load(join("backends", "lock.js"));
  if (typeof resolveTasksContext !== "function" || typeof withLock !== "function") {
    throw new Error("this tasks-axi has no resolveTasksContext or withLock");
  }
  const overrides = { cwd: root };
  if (file) overrides.file = file;
  const { store } = resolveTasksContext(overrides);
  for (const name of ["loadForUpdate", "findEntry", "persist"]) {
    if (typeof store[name] !== "function") throw new Error(`this tasks-axi store has no ${name}`);
  }
  return withLock(store.path, async () => {
    if (inside) await inside(store);
    const loaded = store.loadForUpdate();
    const found = store.findEntry(loaded.doc, id);
    if (found && found.entry.task.state !== "done") {
      return { verdict: "keep", state: found.entry.task.state, cleared: [] };
    }
    const cleared = [];
    for (const section of loaded.doc.sections) {
      for (const entry of section.entries) {
        if (entry.kind !== "task" || entry.task.id === id) continue;
        const before = entry.task.deps.length;
        entry.task.deps = entry.task.deps.filter((d) => !(d.type === "blocked-by" && d.id === id));
        if (entry.task.deps.length === before) continue;
        entry.dirty = true;
        const left = entry.task.deps.filter((d) => d.type === "blocked-by").map((d) => d.id);
        cleared.push({ dependent: entry.task.id, left });
      }
    }
    if (cleared.length > 0) store.persist(loaded);
    return { verdict: "clear", state: found ? "done" : "absent", cleared };
  });
}

// Run as a command only when this file is the main module (import.meta.main, or the script path
// on older node), never when another module imports it.
const invoked = import.meta.main === undefined
  ? Boolean(process.argv[1]) && import.meta.url === pathToFileURL(process.argv[1]).href
  : import.meta.main === true;
if (invoked) {
  const [pkg, root, file, id] = process.argv.slice(2);
  if (!pkg || !root || !id) {
    process.stderr.write("usage: fm-tasks-axi-locked-unblock.mjs <package-dir> <root> <file> <id>\n");
    process.exit(2);
  }
  try {
    const result = await lockedUnblock({ pkg, root, file, id });
    if (result.verdict === "keep") {
      process.stdout.write(`keep ${result.state}\n`);
    } else {
      process.stdout.write("clear\n");
      for (const c of result.cleared) {
        process.stdout.write(`unblocked ${c.dependent} ${c.left.length ? c.left.join(",") : "-"}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error && error.message ? error.message : String(error)}\n`);
    process.exit(1);
  }
}
