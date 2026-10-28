// Whether this omp session is a Firstmate ship or scout worker, never a home.
//
// omp auto-discovers <cwd>/.omp/extensions, so a worker whose task copy is a
// checkout of this repository loads the primary extensions beside the home's
// own. Those extensions resolve their home from FM_HOME and fall back to the
// directory they were loaded from, which in a task copy is the copy itself, so
// the worker session wrote the home's markers and the primary watch state into
// the copy. The worker's own supervision comes from its per-task extension
// (bin/fm-spawn.sh), so the primary extensions stand down for it.
//
// bin/fm-spawn.sh exports FM_TASK_ID into every ship and scout pane, keeps it
// through the filtered launch environment, and never sets it for a primary or
// a secondmate home; bin/fm-test-run.sh reads the same marker.
export function taskWorkerSession(): boolean {
  return Boolean(process.env.FM_TASK_ID);
}
