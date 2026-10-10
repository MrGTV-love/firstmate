# usage: diff.sh <bin-dir> <locale>   -> prints every reader's output, escaped
lib=$1; loc=$2
. "$lib/fm-classify-lib.sh"
command -v _fm_status_open_decision_origins >/dev/null || . "$lib/fm-status-wake-lib.sh"
export LC_ALL=$loc
d=$(mktemp -d)
mk() {  # <name> <kind> ; stdin = content
  mkdir -p "$d/$1"; printf 'kind=%s\n' "$2" > "$d/$1/lane.meta"; cat > "$d/$1/lane.status"
}
{
  printf 'working: start\n'
  printf 'needs-decision [key=alpha] [at=100]: first alpha question\n'
  printf 'blocked [key=beta] [at=10:30]: beta waits\n'
  printf 'note [at=120]: mentions [key=alpha] in prose\n'
  printf 'needs-decision: [key=gamma] colon-form gamma\n'
  printf 'needs-decision [corr=c1] [key=delta]: corr then key\n'
  printf 'needs-decision [corr=c2]: corr no key\n'
  printf 'needs-decision [key=pending-reply-x1]: not the vocabulary\n'
  printf 'needs-decision [key=pending-reply-x2]: pending-reply-missed: real escalation\n'
  printf 'needs-decision [key=bad slug]: malformed key\n'
  printf 'resolved [key=alpha]: answered alpha\n'
  printf 'captain-held [key=beta]: held beta\n'
  printf 'needs-decision [key=eps]: tab\tinside\tand trailing\t\t\n'
  printf 'needs-decision [key=zeta]:\xe3\x80\x80 ideographic space lead\n'
  printf 'needs-decision [key=eta]: caf\xc3\xa9 \xff mid invalid\n'
  printf 'needs-decision [key=theta]: trunc \xe2\x80 cut\n'
  printf 'paused: a pause\n'
  printf 'resolved: default retract\n'
  printf 'needs-decision [key=alpha] [at=300]: alpha again\n'
  printf 'blocked \xff[key=iota]: bad verb byte\n'
  printf 'needs-decision\n'
  printf '   needs-decision [key=kappa]   :   spaced\n'
  printf 'needs-decision [key=lam.da]: dotted key\n'
  printf 'resolved [key=lam]: near miss\n'
  printf 'done: finished\n'
  printf 'needs-decision [key=mu]: after done\n'
} > "$d/base.txt"
mk sm secondmate < "$d/base.txt"
mk ship ship < "$d/base.txt"
mk scout scout < "$d/base.txt"
awk 'BEGIN { pad = sprintf("%60s", ""); gsub(/ /, "\303\251", pad)
  for (i = 1; i <= 30; i++) printf "needs-decision [key=w%02d] [at=%d]: q %d %s\n", i, 1700000000+i, i, pad
  for (i = 1; i <= 30; i += 2) printf "resolved [key=w%02d]: ok\n", i }' | mk wide secondmate
for t in sm ship scout wide; do
  f=$d/$t/lane.status
  printf '### %s open\n' "$t"; status_open_decisions "$f" | od -An -c
  printf '### %s dated\n' "$t"; status_open_decisions_dated "$f" | od -An -c
  printf '### %s activities\n' "$t"; status_open_activities "$f" | od -An -c
  printf '### %s origins\n' "$t"; _fm_status_open_decision_origins "$f" | od -An -c
  for k in alpha beta gamma delta default pending-reply-x1 pending-reply-x2 eps eta theta lam.da lam mu w01 w02; do
    printf '### %s closing %s=[%s]\n' "$t" "$k" "$(status_key_closing_verb "$f" "$k" 2>/dev/null)"
  done
  cp -R "$d/$t" "$d/$t-inc"; fi=$d/$t-inc/lane.status
  printf '### %s inc1\n' "$t"; status_open_decisions_incremental "$fi" | od -An -c
  printf 'resolved [key=mu]: closed mu\nneeds-decision [key=nu]: new nu\n' >> "$fi"
  printf '### %s inc2\n' "$t"; status_open_decisions_incremental "$fi" | od -An -c
  printf '### %s open-after-checkpoint\n' "$t"; status_open_decisions "$fi" | od -An -c
done
while IFS= read -r line; do
  printf '### line %q verb=[%s] note=[%s] key=[%s] rc=%s\n' "$line" "$(status_line_verb "$line")" "$(status_line_note "$line")" "$(_fm_decision_key "$line")" "$?"
  for set in '' $'a\tneeds-decision\tx\n' $'a\tneeds-decision\tx\nalpha\tblocked\ty\n\n' $'eps\tneeds-decision\tz'; do
    printf '  fold=%q\n' "$(_fm_decision_fold_line "$set" "$line" resolved captain-held secondmate; printf .)"
    printf '  foldship=%q\n' "$(_fm_decision_fold_line "$set" "$line" resolved captain-held ship; printf .)"
  done
done < "$d/base.txt"
for set in '' $'a\tx\ty' $'a\tx\ty\n' $'b\tx\ty\na\tx\ty\nc\tq\tr\n\n' $'a.b\tx\ty\naxb\tx\ty'; do
  for k in a a.b axb c zz; do
    printf '### drop %q %s stdout=%q' "$set" "$k" "$(_fm_decision_drop "$set" "$k"; printf .)"
    out=; _fm_decision_drop "$set" "$k" out; printf ' var=%q\n' "$out"
  done
done
rm -rf "$d"
