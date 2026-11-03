# Shared fixture helpers for the live scenarios. Sourced from one shell.
OWNER="$PWD/bin/fm-github-accounting.py"
make_caller() { # <dir>: a #!/bin/sh "gh" that runs sleep without exec, so a live process shows the script path
  mkdir -p "$1"
  cat > "$1/gh" <<'F'
#!/bin/sh
sleep "${FIX_SECS:-30}"
F
  chmod +x "$1/gh"
  cat > "$1/fixture-parent.sh" <<'F'
#!/bin/sh
# runs the fixture gh with the arguments given, without exec, so it stays the parent
"$@"
F
  chmod +x "$1/fixture-parent.sh"
}
wait_gone() { local i; for i in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
