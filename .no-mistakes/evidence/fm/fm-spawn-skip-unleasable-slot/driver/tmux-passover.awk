# Rewrites tests/fm-spawn-acquisition-real-treehouse.test.sh into an evidence driver:
# after the spawn returns, print its output, the second get's liveness (ps -p), the acquisition
# window, acquisition-pane.tsv and skipped-copies.tsv into the log L. Drops the mutant control case.
/^  rc=\$\?$/ && !done1 {
  print
  print "  { printf '\\n===== [%s] fm-spawn.sh output (exit %s) =====\\n' \"$label\" \"$rc\"; printf '%s\\n' \"$out\"; } >> '" L "'"
  done1 = 1; next
}
/^  get2=\$\(cat "\$case\/pid"\)$/ {
  print
  print "  evidence_dump >> '" L "'"
  next
}
/^# The control restores/ { skip = 1 }
/^run_passover_inflight_case passover-stubborn/ { skip = 0 }
!skip { print }
