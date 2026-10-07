// Disposable package-shape safety variant: real adviser modules and real omp host,
// with only the optional host rebuilder deliberately absent from the adapter object.
import * as judge from "../.fm-adviser-root/node_modules/compact-adviser/src/judge.ts";
import * as context from "../.fm-adviser-root/node_modules/compact-adviser/src/context.ts";
import * as config from "../.fm-adviser-root/node_modules/compact-adviser/src/config.ts";
import * as env from "../.fm-adviser-root/node_modules/compact-adviser/src/env.ts";
import * as profile from "../.fm-adviser-root/node_modules/compact-adviser/src/profile.ts";
import * as state from "../.fm-adviser-root/node_modules/compact-adviser/src/state.ts";
import { startPipeline } from "../extensions/omp-jev-pipeline.mjs";
export default function missingHostAdapter(api) {
  startPipeline(api, { ...judge, ...context, ...config, ...env, ...profile, ...state });
}
