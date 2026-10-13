#!/usr/bin/env bash
# Build the disposable Firstmate lab home for the omp direct-judge validation.
# Usage: lab-setup.sh <lab-root> <firstmate-code-root>
set -euo pipefail
ROOT=$1 FMR=$2
W=$ROOT/work
LAB=$ROOT/home
"$FMR/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects" "$ROOT/treehouse" "$ROOT/origins"
printf 'tmux\n' > "$LAB/config/backend"
printf 'omp\n' > "$LAB/config/crew-harness"
# Fake primary-home keys only. The OpenRouter key is a credentialed trap.
printf 'TYPESAFE_API_KEY=fake-lab-typesafe-primary\nOPENROUTER_API_KEY=fake-lab-openrouter-trap\n' > "$LAB/.env"
chmod 600 "$LAB/.env"

make_project() {  # <name>
  local name=$1 seed="$ROOT/origins/$1-seed" origin="$ROOT/origins/$1.git"
  mkdir -p "$seed"
  git init -q -b main "$seed"
  printf 'export function add(a: number, b: number) { return a + b; }\n' > "$seed/counter.ts"
  printf '# %s\n\nA tiny lab project.\n' "$name" > "$seed/README.md"
  git -C "$seed" add -A
  git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m "seed $name"
  git clone -q --bare "$seed" "$origin"
  rm -rf "$seed"
  git clone -q "$origin" "$LAB/projects/$name"
}
make_project firstmate
make_project vernant
printf '# Projects\n\n- firstmate [local-only +yolo] - lab stand-in for the firstmate project\n- vernant [local-only +yolo] - lab stand-in for a non-firstmate project\n' > "$LAB/data/projects.md"
"$FMR/bin/fm-lab-home.sh" tmux-dir "$LAB"
