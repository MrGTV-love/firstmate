. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/s6lib.sh
for spec in "lnest1 unique present" "lnest2 clean present"; do set -- $spec
  echo "######## S6 nested anchored prior, bytes=$2, current copy $3"
  nested_case $1 $2 $3 || { echo setup failed; exit 1; }
  teardown $1 2>&1 | f; echo "exit=${PIPESTATUS[0]}"; report $1
done
