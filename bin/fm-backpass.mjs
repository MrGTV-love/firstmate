#!/usr/bin/env node
// Firstmate's bare-shell Backpass caller. Install this entry as `backpass` after
// adopting the reviewed core at data/tools/backpass/node_modules/backpass under
// the installation home (FM_HOME or this caller's home). That home's
// data/tools/backpass/package.json names the repository bound to the approved
// Sol/high application policy in firstmateBackpassRepository.
// firstmateBackpassPolicyHome separately binds the governing model-index home;
// the core/caller installation directory never substitutes for that policy home.
// In that repository only, otherwise-unset roles receive the current Sol release at
// high effort, and every complete role selection must match that current release.
// Elsewhere and in user scope the caller supplies no defaults and leaves complete
// explicit selections to the core's own rules. The current release comes from
// fm-model-index latest, never a release pin or fallback ladder.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const home = process.env.FM_HOME || root;
const prefix = path.join(home, "data/tools/backpass");
const corePath = path.join(prefix, "node_modules/backpass");

function boundDirectory(field) {
  let bound;
  try {
    bound = JSON.parse(fs.readFileSync(path.join(prefix, "package.json"), "utf8"))[field];
  } catch (error) {
    throw new Error(`no readable ${field} binding in ${prefix}/package.json: ${error.message}`);
  }
  if (typeof bound !== "string" || !path.isAbsolute(bound)) {
    throw new Error(`${field} in ${prefix}/package.json must be an absolute directory path`);
  }
  try {
    const directory = fs.realpathSync(bound);
    if (!fs.statSync(directory).isDirectory()) throw new Error("not a directory");
    return directory;
  } catch (error) {
    throw new Error(`${field} in ${prefix}/package.json names no readable directory: ${error.message}`);
  }
}

function inBoundScope(repoRoot, bound) {
  return repoRoot != null && fs.realpathSync(repoRoot) === bound;
}

let discovery;
function currentModel() {
  discovery ??= promisify(execFile)(
    path.join(root, "bin/fm-model-index.sh"),
    ["latest", "omp", "openai-codex/gpt", "sol"],
    { env: { ...process.env, FM_HOME: boundDirectory("firstmateBackpassPolicyHome") } },
  ).then(({ stdout }) => {
    const model = stdout.trim();
    if (!/^openai-codex\/[^\s]+$/.test(model)) throw new Error("current-model discovery returned no exact subscription model");
    return model;
  });
  return discovery;
}

try {
  const core = await import(pathToFileURL(path.join(corePath, "src/cli.js")).href);
  if (core.APPLICATION_ROLE_INPUT_VERSION !== 2) {
    throw new Error("the adopted Backpass core does not support validated application role inputs; refusing an older core");
  }
  process.exitCode = await core.main(process.argv.slice(2), {
    roleDefaults: async ({ roles, repoRoot }) => {
      if (repoRoot == null || !inBoundScope(repoRoot, boundDirectory("firstmateBackpassRepository"))) return {};
      const model = await currentModel();
      return Object.fromEntries(roles.map((role) => [role, { agent: "omp", model, effort: "high" }]));
    },
    validateRoles: async ({ roles, selections, repoRoot }) => {
      let bound;
      try {
        bound = boundDirectory("firstmateBackpassRepository");
      } catch {
        return;
      }
      if (!inBoundScope(repoRoot, bound)) return;
      const model = await currentModel();
      for (const role of roles) {
        const selection = selections[role];
        if (selection.agent !== "omp" || selection.model !== model) {
          throw new Error(
            `the ${role} role selects ${selection.agent}/${selection.model}, but this repository requires omp/${model}, the current eligible Sol release`,
          );
        }
        if (typeof selection.effort !== "string" || !selection.effort.trim()) {
          throw new Error(`the ${role} role has no explicit effort`);
        }
      }
    },
  });
} catch (error) {
  console.error(`backpass: ${error.message}`);
  process.exitCode = 1;
}
