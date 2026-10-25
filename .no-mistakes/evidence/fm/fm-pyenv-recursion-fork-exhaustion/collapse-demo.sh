#!/bin/bash
# Shows how each [ wrapper answers pyenv-prefix's "is this version system?" question.
for w in wrapper-old.sh wrapper-new.sh; do
  /bin/bash -c '
    . "$1"
    version=3.13.6
    for ifs in default colon; do
      if [ "$ifs" = colon ]; then IFS=:; fi
      if [ "$version" = "system" ]; then r="TRUE (wrong)"; else r="false (right)"; fi
      IFS=$'"'"' \t\n'"'"'
      echo "$1 IFS=$ifs: [ 3.13.6 = system ] -> $r"
    done' _ "$w"
done
echo "bash: $(/bin/bash --version | head -1)"
