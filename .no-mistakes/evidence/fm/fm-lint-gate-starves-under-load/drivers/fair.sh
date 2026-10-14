#!/usr/bin/env bash
# fair.sh <label> <lint-bin> <slot-dir>: cap 1; run A (--jobs 2, roots c1..c10)
# starts first and builds a backlog; run B (--jobs 1, roots c11..c15) joins.
set -u
LAB=$(cat /tmp/fm-lint-lab-path.txt)
label=$1 bin=$2 slots=$3
out="$LAB/out/$label"; rm -rf "$out"; mkdir -p "$out"
perl "$LAB/order.pl" "$LAB/fx/" "$out/order.tsv" "$out/stop" &
sampler=$!
A=(); for i in $(seq 1 10); do A+=("$LAB/fx/c$i.sh"); done
B=(); for i in $(seq 11 15); do B+=("$LAB/fx/c$i.sh"); done
FM_LINT_HOST_SLOTS=${CAP:-1} LINT_BIN="$bin" LAB_SLOTS="$slots" "$LAB/lint.sh" --jobs 2 --telemetry "$out/A.tsv" "${A[@]}" > "$out/A.log" 2>&1 &
pa=$!
until grep -q start "$out/order.tsv" 2>/dev/null; do sleep 0.05; done
sleep 0.5
FM_LINT_HOST_SLOTS=${CAP:-1} LINT_BIN="$bin" LAB_SLOTS="$slots" "$LAB/lint.sh" --jobs 1 --telemetry "$out/B.tsv" "${B[@]}" > "$out/B.log" 2>&1 &
pb=$!
wait "$pa"; ra=$?; wait "$pb"; rb=$?
touch "$out/stop"; wait "$sampler"
echo "== $label: cap=${CAP:-1}; run A --jobs 2 roots c1-c10 (started first); run B --jobs 1 roots c11-c15"
echo "A rc=$ra  B rc=$rb"
awk -F '\t' '$2=="start"{n=$3; sub(/\.sh$/,"",n); r=(substr(n,2)+0<=10)?"A":"B"; seq=seq r; printf "%s %-4s %s\n", $1, n, r} $1=="MAX"{print "peak_concurrent_shellcheck=" $2} END{print "start_sequence=" seq}' "$out/order.tsv"
