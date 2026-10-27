const [plugin, root, cmd] = process.argv.slice(2);
const { FmPrimaryCdCheck } = await import(plugin);
const hooks = await FmPrimaryCdCheck({ directory: root, worktree: root });
try { await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: cmd } }); console.log("OPENCODE: command allowed to run (no throw)"); }
catch (e) { console.log("OPENCODE: command BLOCKED (throw): " + e.message.slice(0, 120)); }
