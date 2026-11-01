SMH=$SCR/sm-home; SMH=$(cd "$SMH" && pwd -P)
echo; echo "=== S7d: after the bundle left the home: drop the live lab child inside the home, then ordinary retirement ==="
( export FM_HOME=$SMH; td c-live --force --drop-file "$SCR/captain-words.txt" | grep -e 'complete (' -e REFUSED -e '^\[exit' | cut -c1-200 )
td t-s7 | grep -v '^🌳' | tail -4 | cut -c1-250
present "$SMH"; present "$SCR/durable"; ls "$SCR/durable"; present "$FM_HOME/state/t-s7.meta"
