#!/usr/bin/env bash
# usage: adversarial.sh <tree-with-bin/fm-lint-cache.pl> <workdir>
set -u
src=$1 work=$2
rm -rf "$work"; mkdir -p "$work/bin" "$work/tests"
cp "$src/bin/fm-lint-cache.pl" "$src/bin/fm-lint.sh" "$work/bin/"
cd "$work"
w() { printf '%s\n' '#!/usr/bin/env bash' "$2" > "bin/$1"; }
w lib.sh 'lib_fn() { echo ok; }'
w leaf.sh 'echo leaf'
w top-unknown.sh '. "$DYN"'
w child-dynamic.sh "bash -c '. \"\$1\"' _ \"\$DYN\""
w heredoc-dynamic.sh $'bash <<\'EOF\'\n. "$DYN"\nEOF'
w child-static.sh "bash -c '. bin/lib.sh; lib_fn'"
w child-mixed.sh "bash -c '. bin/lib.sh; . \"\$X\"'"
w heredoc-parent-static.sh $'cat <<EOF\n$(. bin/lib.sh; lib_fn)\nEOF'
w heredoc-parent-unknown.sh $'cat <<EOF\n$(. "$DYN")\nEOF'
w heredoc-arith-unknown.sh $'cat <<EOF\n$(( $(. "$DYN"; echo 1) + 1 ))\nEOF'
w heredoc-param-arith-unknown.sh $'cat <<EOF\n${x:$(( $(. "$DYN"; echo 1) ))}\nEOF'
w heredoc-extglob-case-unknown.sh $'shopt -s extglob\ncat <<EOF\n$(case x in @(a|b)) . "$DYN";; esac)\nEOF'
w heredoc-literal-case-unknown.sh $'cat <<EOF\n$(case x in esac|done) . "$DYN";; esac)\nEOF'
w topcase-extglob-unknown.sh $'shopt -s extglob\ncase x in @(a|b)) . "$DYN";; esac'
sel() { printf '%s\0' "$1" | perl bin/fm-lint-cache.pl select "$2" | tr '\0' ' '; }
sc=$(command -v shellcheck)
chk() { perl bin/fm-lint-cache.pl check "$work/cache" . "$sc" --norc --external-sources -- "$1" --execute true 2>&1; }
cacheable() { rm -rf cache; mkdir cache; chk "$1" >/dev/null; case $(chk "$1") in *"cache hit"*) echo yes;; *) echo no;; esac; }
echo "--- unrelated leaf edit (bin/leaf.sh), root='.': selected ="; echo "  $(sel bin/leaf.sh .)"
echo "--- unrelated leaf edit, root=abs: selected ="; echo "  $(sel bin/leaf.sh "$work")"
echo "--- bin/lib.sh edit: selected ="; echo "  $(sel bin/lib.sh .)"
echo "--- cacheable per root:"
for f in bin/*.sh; do case $f in bin/fm-lint.sh) continue;; esac; printf '  %-40s %s\n' "$f" "$(cacheable "$f")"; done
echo "--- lib.sh is a cache input? (warm cache, edit lib.sh, re-check):"
for f in bin/child-static.sh bin/heredoc-parent-static.sh; do
  rm -rf cache; mkdir cache; cp bin/lib.sh /tmp/.lib.$$; chk "$f" >/dev/null; echo '# edit' >> bin/lib.sh
  case $(chk "$f") in *"cache hit"*) r="hit after lib edit (lib NOT an input)";; *) r="miss after lib edit (lib IS an input)";; esac
  cp /tmp/.lib.$$ bin/lib.sh; rm -f /tmp/.lib.$$; printf '  %-40s %s\n' "$f" "$r"
done
