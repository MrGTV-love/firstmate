// Copy this entry to ../.fm-adviser-root/omp-jev-entry.mjs after installing
// compact-adviser there, then explicitly load the copy with omp -e <copy>.
// Static imports let the compiled omp loader resolve/rewrite the complete
// dependency graph; computed dynamic imports bypass that supported loader.
// FM_JEV_OMP_PIPELINE=1 is required; see docs/configuration.md for bake-off setup.
import * as judge from "compact-adviser/src/judge.ts";
import * as context from "compact-adviser/src/context.ts";
import * as config from "compact-adviser/src/config.ts";
import * as env from "compact-adviser/src/env.ts";
import * as profile from "compact-adviser/src/profile.ts";
import * as state from "compact-adviser/src/state.ts";
import { buildSessionContext } from "@earendil-works/pi-coding-agent";
import { startPipeline } from "../extensions/omp-jev-pipeline.mjs";

export default function ompJevPipeline(api) {
  startPipeline(api, { ...judge, ...context, ...config, ...env, ...profile, ...state, buildSessionContext });
}
