printf 'x\n' > "$LAB/x"
scenario probe-path target 'command -v no-mistakes gh-axi' "$LAB/x" 0
