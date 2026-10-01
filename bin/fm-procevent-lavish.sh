#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html> [--for <task-id>] [--agent-reply-file <path>]
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh silent <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh reconciles <result-file>
#   fm-procevent-lavish.sh read <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#   fm-procevent-lavish.sh sweep [--dry-run]
#   fm-procevent-lavish.sh poll <artifact.html> [--agent-reply-file <path>]
#   fm-procevent-lavish.sh deliver-reply poll <artifact.html> --agent-reply-file <path>
#   fm-procevent-lavish.sh check <artifact.html>
#   fm-procevent-lavish.sh relisten [<result-file>]
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, disconnected, missing, or unknown.
# read       Print a structured presentation of one already-captured result so a
#            handler consumes every queued item without grepping the raw file.
#            It is read-only over the capture: it does not arm, poll, or change
#            what Lavish delivered. The freeform message (tag=message) is its
#            own labeled field, printed first and distinct from per-element
#            annotations; it is labeled SESSION-ENDING MESSAGE, and counted as
#            session_ending_message_count, only when the session ended, and is
#            otherwise CAPTAIN MESSAGE and captain_message_count. Declared and
#            presented item counts,
#            plus a completeness verdict, follow before all annotations so a
#            partial read is obvious. Each annotation retains its element uid,
#            selector, tag, and text. A non-choice freeform comment (`prompt`)
#            is printed as its own field even when a selector is also present
#            and even when that comment matches the element text, so typed
#            words are never dropped. Choice Context data is not a comment.
#            Captain-supplied body lines are visibly prefixed so they cannot
#            forge structural labels. Empty message and annotation sections
#            are reported explicitly.
# sweep      Retire this home's Lavish listeners whose boards are finished, and
#            print one `retired:`, `kept:` or (with --dry-run) `would-retire:`
#            line per registration plus a `sweep:` total. Choice answers do not
#            end Lavish sessions, so idle boards need explicit listener retirement.
#            Keep guards run first: the standing Bearings board, unreadable or
#            ambiguous Lavish session evidence, queued feedback or status
#            feedback, then worker-task ownership. These guards also apply after
#            the artifact is deleted. The standing-board exemption survives a
#            deleted symlink target; an unresolved chain keeps every listener.
#            Board and inbox lookup, stat, enumeration and read errors keep the
#            affected listener with a reason; confirmed absence is not a read error.
#            Otherwise a board is FINISHED when its artifact file is confirmed
#            gone, or when Lavish holds no session or an ended session for it and
#            every card key is known not to name an open captain call. Other
#            boards must also be idle for FM_BOARD_LISTENER_IDLE_HOURS (default
#            48, whole hours 1..8760); an unusable value refuses the sweep by name.
#            Activity is the latest artifact mtime, session updated_at, or mtime
#            of this source's inbox entries, including handled acknowledgements.
#            Static discovery recognizes quoted and unquoted question attributes,
#            case-insensitive attribute names and decoded HTML entities. Zero keys,
#            scripts, event handlers, embedded surfaces, unkeyed forms, malformed
#            markup, valueless question attributes and invalid decoded keys leave
#            discovery unknown and keep a present board, even alongside static keys.
#            `bin/fm-captain-hold.sh open-bound` checks keys in source-binding
#            context; only exit 1 (resolved and not an open captain call) permits
#            retirement. Its header owns the binding and key-resolution contract.
#            A call held in another home's backlog is invisible here, so dormancy
#            is the safeguard for live sessions.
#            An unacknowledged captured round blocks every sweep retirement.
#            Retirement uses the generic `retire --if-identity` boundary, whose
#            header owns generation checks, inbox revalidation and capture limits.
#            It stops the listener and releases its claim without ending the
#            Lavish session, so the board stays readable and `arm` brings it back.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It runs the published blocking poll
#            and prints its response verbatim, absorbing only the one exact
#            transient interruption described below. A staged reply still
#            present when it starts is posted before the long-poll: through
#            `lavish-axi reply` when supported, otherwise through the legacy
#            best-effort `poll --agent-reply` path.
# deliver-reply
#            Run by `fm-procevent.sh register-task` under the source lock, only
#            after the task is eligible to own the board, with the listener argv
#            it is about to publish. Exit 0 once Lavish accepts the staged reply,
#            3 when the installed Lavish is a confirmed older release without
#            synchronous reply so the listener keeps the legacy path, and any
#            other status when the reply failed or the version is unknown.
# check      Compile, without running, inline event handlers and inline classic
#            scripts; exit 1 naming each parse failure and its source line.
#            Skip external, module, JSON and other non-classic scripts, and
#            commented-out markup; HTML-like comments inside live JavaScript
#            remain part of the script body. This is a syntax-only check, not
#            proof that handlers run, cancel submission or queue answers.
#            `node` must be on PATH unless extraction yields no entries.
#            Direct `check` needs a readable file, not a final-component symlink;
#            `arm` resolves symlinks and checks the physical file it will poll.
#            docs/configuration.md owns the arm-time refusal contract.
#            A malformed onsubmit can leave native form submission uncancelled,
#            sending the artifact frame to Lavish's 409 "no longer current"
#            page; reloading cannot repair malformed JavaScript in the file.
#            Build handlers with addEventListener or read their text from data
#            attributes instead of pasting text into quoted handler strings.
#            Run `check` while building a board, before opening it.
#            It warns, without failing, when inline onsubmit handlers exist but
#            no live script carries data-fm-lavish-form-guard. Paste the guard in
#            .agents/skills/bearings/assets/lavish-form-guard.html once into such
#            a board; its local comment owns the guard's runtime guarantees.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
# relisten   Keep the same runner and exclusive claim through feedback,
#            disconnects, waiting, and empty poll returns, but surface unknown
#            failures without retrying them forever. The optional result file
#            is the runner's unhandled-capture continuation check; without one,
#            it is an empty or handled round. Quiet rounds wait poll_retry_delay
#            seconds before another poll. Worker-owned feedback still waits for
#            its owner's acknowledgement.
# silent     Exit 0 when the captured result is a routine no-op the runner should
#            record and never announce; any other exit publishes the wake. This
#            is the generic no-op contract bin/fm-procevent.sh calls, and the
#            only place Lavish's notion of "nothing was said" is decided.
#            Task-owned terminal rounds bypass generic silence so their owner
#            receives the stop-and-conclude instruction.
#
# AN EMPTY BOARD CLOSE IS NOT NEWS, and that is what `silent` exists to say.
# Closing a review surface that carried nothing is the single most common Lavish
# result: the captain reads a board, says nothing, and closes it. Announcing that
# put a wake in front of the handler whose entire content was that nothing
# happened. `silent` therefore holds two narrow, positively-determined shapes -
# a session this adapter classifies `ended` that carries no queued content block
# at all, or `browser_disconnected`, which carries no answer while the session
# remains open - and every other result stays announced.
#
# Deliberately narrow, in both directions. A `Send & End` close carrying the
# captain's actual answer arrives as `status: feedback` with `session_ended`, so
# it classifies `feedback`, never `ended`, and is announced exactly as before; so
# is any `ended` result that still carries a `prompts` or `feedback` block, which
# the published poll is not expected to produce but which must never be dropped
# on that expectation. A `waiting` session, a `missing` one, an `unknown` or
# unreadable result, and any error all stay announced, because none of them
# positively proves nothing was said. Silence is only ever an absence this
# adapter can see in the result, never an absence it assumes.
#
# This adapter owns Lavish-specific board checks, canonical source identity,
# the argv for the currently published poll command, and completed-result
# interpretation. Ownership, durable capture, publication, and restart recovery
# all belong to bin/fm-procevent.sh.
#
# The published poll vocabulary includes feedback, ended, waiting, and
# browser_disconnected. A waiting result from this no-timeout poll means a
# second poller was present; it is not a normal idle round. browser_disconnected
# means the session remains open and is handled as a silent reconnect wait.
# Before each poll attempt, resolve the artifact's saved URL from Lavish's own
# session store (LAVISH_AXI_STATE_DIR/state.json, default ~/.lavish-axi/state.json)
# and use its host and port. Opening the board writes that URL; polling does not.
# This is a routing lookup before the blocking call, not presence polling or a
# second route record. Ambient/configured addresses must not retarget a reply.
# An unreadable session stops before the staged reply is consumed; an absent
# saved session emits NOT_FOUND for the runner's existing terminal retire path.
# Lavish rewrites that store in place, so a store that does not decode may be a
# half-written snapshot: it is re-read under the quiet retry bound below, and is
# refused only while still undecodable once that bound is spent.
#
# `answers` is this adapter's half of the generic keyed-answer contract in
# bin/fm-procevent.sh. It reports what the captain actually chose, as
# `<task-id>\t<answer>\t<label>` lines, and stops there. It maps nothing to a
# task, records no decision, and closes nothing: a captain answer is not special
# to Lavish, so every rule about what a keyed answer DOES belongs to the one
# intake in bin/fm-captain-hold.sh, which the runner feeds. A Lavish review is
# just an ephemeral discussion format that happens to carry answers.
#
# Only rows tagged `choice` are read. A freeform captain message is prose that may
# contain anything, and must never be able to forge a decision key.
#
# `read` is the presentation command summarized above; keyed intake remains
# the separate `answers` contract described here.
#
# It wraps the published `lavish-axi poll` and `lavish-axi reply` interfaces,
# verified against 0.1.80. `poll` long-polls indefinitely; `reply` exits only
# after the server confirms acceptance. Older compatible versions retain the
# legacy poll-with-reply path, without the synchronous handoff guarantee.
#
# BOUNDED QUIET RETRY, owned here and nowhere else. A live listener can be cut
# short by the server with exactly this two-line response while the session's
# marks remain available:
#
#   error: Lavish Editor poll response was interrupted
#   code: SERVER_ERROR
#
# lavish-axi 0.1.79 follows those two lines with one generated `help[2]:` footer
# naming the server log and the poll re-run; that exact three-line form is the
# same interruption. Every listener sees it when the Lavish server restarts.
#
# That is an internal retry, not news, so registering the raw poll made the
# generic runner capture it and wake the whole fleet. `poll` therefore re-runs
# the published poll up to POLL_RETRY_LIMIT times for that exact response, with
# attempt starts at least POLL_RETRY_DELAY_DEFAULT seconds apart. The match is exact and
# deliberately narrow: real feedback, ended and missing sessions, any other
# SERVER_ERROR, and the same interruption still standing after the bound is
# spent are all printed straight through and captured normally. The retry is a
# Lavish fact, so the generic runner in bin/fm-procevent.sh stays
# adapter-agnostic and learns nothing about it.
#
# A blocking poll whose lavish-axi process is killed by a signal before it
# prints anything exits 75, the runner's existing poll-again status, so the same
# runner relistens at once instead of leaving the source unowned until
# reconciliation. Any output, or any other non-zero exit, is handled as before.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

apply_session_host() {  # <artifact>
  local endpoint rc
  endpoint=$(perl -MJSON::PP -MCwd=realpath -MEncode=decode,FB_CROAK -e '
    use strict;
    use warnings;
    my ($path, $artifact) = @ARGV;
    my $real = realpath($artifact) // die "cannot resolve board artifact\n";
    $real = decode("UTF-8", $real, FB_CROAK);
    open my $file, "<", $path or die "cannot read Lavish session store\n";
    -f $file or die "Lavish session store is not a regular file\n";
    local $/;
    my $state = eval { decode_json(<$file>) };
    exit 4 if $@;
    ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH"
      or die "invalid Lavish session store\n";
    my @sessions = grep {
      ref($_) eq "HASH" && defined($_->{file}) && $_->{file} eq $real
    } values %{$state->{sessions}};
    exit 3 unless @sessions;
    @sessions == 1 or die "board must have one saved Lavish session\n";
    my $url = $sessions[0]->{url} // "";
    $url =~ m{\Ahttp://(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):([0-9]+)/session/[0-9a-f]{16}(?:\?[^\s#]*)?\z}
      or die "invalid saved Lavish session URL\n";
    my ($host, $port) = ($1, $2);
    $host =~ s/^\[|\]$//g;
    $host ne "0.0.0.0" && $host ne "::" && $port >= 1 && $port <= 65535
      or die "invalid saved Lavish server address\n";
    print "$host\n$port\n";
  ' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json" "$1")
  rc=$?
  case "$rc" in
    0) ;;
    3|4) return "$rc" ;;
    *) die "cannot resolve the board server from its Lavish session: $1" ;;
  esac
  LAVISH_AXI_HOST=${endpoint%$'\n'*}
  LAVISH_AXI_PORT=${endpoint##*$'\n'}
  export LAVISH_AXI_HOST LAVISH_AXI_PORT
}

lavish_reply_compatible() {
  local status=0
  "$FM_ROOT/bin/fm-bootstrap.sh" lavish-reply-compatible >/dev/null 2>&1 || status=$?
  case "$status" in
    0|1) return "$status" ;;
  esac
  die "cannot confirm a supported lavish-axi version, so the staged reply was not posted; retry once \`lavish-axi --version\` reports a supported release"
}

post_lavish_reply() {  # <artifact> <reply-file>
  local output
  if ! output=$(lavish-axi reply "$1" --agent-reply-file "$2" 2>&1); then
    [ -n "$output" ] || output="lavish-axi reply exited nonzero"
    die "Lavish did not accept the staged reply: $output"
  fi
}

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

# Handler bodies are compiled as the function body a browser wraps them in.
# The header owns check scope and limits; extraction must preserve live script
# bodies while excluding commented-out markup from both compilation and guard
# detection.
board_extract_scripts() {  # <artifact> <out-json-file>
  perl -MJSON::PP -MEncode=decode,FB_DEFAULT -e '
    use strict; use warnings;
    my ($path, $out) = @ARGV;
    open my $in, "<:raw", $path or exit 2;
    local $/;
    # Scan bytes, not characters: character offsets into a large non-ASCII page
    # cost a pass over the text each, so only the extracted pieces are decoded.
    my $html = <$in>;
    close $in;
    my $text = sub { decode("UTF-8", $_[0], FB_DEFAULT) };
    my @items;
    # Offsets arrive in ascending order within one text, so count only the
    # newlines since the previous offset instead of rescanning from the start.
    my $line_counter = sub {
      my ($text, $at, $line) = (shift, 0, 1);
      return sub {
        my ($pos) = @_;
        if ($pos < $at) { ($at, $line) = (0, 1); }
        $line += substr($text, $at, $pos - $at) =~ tr/\n//;
        $at = $pos;
        return $line;
      };
    };
    my $html_line = $line_counter->($html);
    sub unescape {
      my ($v) = @_;
      $v =~ s/&#[xX]([0-9a-fA-F]+);/chr(hex($1))/ge;
      $v =~ s/&#([0-9]+);/chr($1)/ge;
      $v =~ s/&quot;/"/g;
      $v =~ s/&apos;/\x27/g;
      $v =~ s/&lt;/</g;
      $v =~ s/&gt;/>/g;
      $v =~ s/&amp;/&/g;
      return $v;
    }
    # Match comments and live scripts in one scan so inactive script tags never
    # count as code or guards, without stripping comment-like JavaScript text.
    # Blank their bodies, preserving newlines for subsequent handler locations.
    my $markup = $html;
    $markup =~ s{<!--.*?(?:-->|\z)|(<script\b([^>]*)>)(.*?)(</script\s*>)}{
      my ($open, $attrs, $body, $close, $start) = ($1, $2, $3, $4, $-[0]);
      if (defined $open) {
        push @items, { kind => "guard" } if $attrs =~ /\bdata-fm-lavish-form-guard\b/i;
        my $type = $attrs =~ /\btype\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\s>]+))/i
          ? lc($1 // $2 // $3 // "") : "";
        if ($attrs !~ /\bsrc\s*=/i && ($type eq "" || $type =~ m{\A(?:text|application)/(?:x-)?(?:javascript|ecmascript)\z}) && $body =~ /\S/) {
          push @items, { kind => "script", where => "inline script", line => $html_line->($start + length($attrs) + 8), body => $text->($body) };
        }
        $open . ($body =~ s/[^\n]//gr) . $close;
      } else {
        $& =~ s/[^\n]//gr;
      }
    }gise;
    my $markup_line = $line_counter->($markup);
    # Linear scan: find each start tag, then read its attributes with \G so no
    # pattern can backtrack across the page.
    pos($markup) = 0;
    while ($markup =~ m{<([A-Za-z][\w:-]*)(?=[\s/>])}g) {
      my ($tag, $start) = (lc $1, $-[0]);
      my (%attr, @order);
      while ($markup =~ m{\G\s*([^\s"\x27<>/=]+)(?:\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\s"\x27=<>`]+)))?}gc) {
        my $name = lc $1;
        $attr{$name} //= unescape($text->($2 // $3 // $4 // ""));
        push @order, $name;
      }
      $markup =~ m{\G\s*/?>}gc;
      my $who = defined $attr{"data-lavish-question"} ? " question " . $attr{"data-lavish-question"}
        : defined $attr{id} ? " #" . $attr{id} : "";
      for my $name (@order) {
        next unless $name =~ /\Aon[a-z]+\z/;
        my $body = $attr{$name};
        next unless defined $body && $body =~ /\S/;
        push @items, { kind => "handler", where => "<$tag>$who $name", line => $markup_line->($start), body => $body };
      }
    }
    open my $fh, ">:raw", $out or exit 2;
    print {$fh} encode_json(\@items);
    close $fh or exit 2;
  ' "$1" "$2"
}

cmd_check() {
  local artifact=${1-} items verdict rc=0
  [ -n "$artifact" ] || usage
  [ -f "$artifact" ] && [ ! -L "$artifact" ] && [ -r "$artifact" ] \
    || die "artifact is not a readable file: $artifact"
  items=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-check.XXXXXX") || die "cannot stage the board check"
  board_extract_scripts "$artifact" "$items" || { rm -f -- "$items"; die "cannot read the board's scripts: $artifact"; }
  if [ "$(cat -- "$items")" = '[]' ]; then
    rm -f -- "$items"
    printf 'check: ok handlers=0 scripts=0\n'
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    rm -f -- "$items"
    die "node is required to verify the board's page scripts and was not found on PATH: $artifact"
  fi
  verdict=$(node -e '
    const vm = require("node:vm");
    let raw = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (d) => { raw += d; });
    process.stdin.on("end", () => {
      const items = JSON.parse(raw);
      let bad = 0, handlers = 0, scripts = 0, submits = 0, guard = 0;
      for (const item of items) {
        if (item.kind === "guard") { guard = 1; continue; }
        if (item.kind === "handler") handlers++; else scripts++;
        if (item.kind === "handler" && / onsubmit$/.test(item.where)) submits++;
        const source = item.kind === "handler" ? "(function(event){" + item.body + "\n})" : item.body;
        try { new vm.Script(source, { filename: "board" }); }
        catch (error) {
          bad++;
          console.log(["FAIL", item.where, "line " + item.line, String(error.message).replace(/\s+/g, " ")].join("\t"));
        }
      }
      console.log(["SUMMARY", handlers, scripts, bad, submits, guard].join("\t"));
      process.exit(bad ? 1 : 0);
    });
  ' < "$items") || rc=$?
  rm -f -- "$items"
  case "$rc" in 0|1) ;; *) die "the board script check did not complete: $artifact" ;; esac
  if [ "$rc" -eq 1 ]; then
    printf 'error: this board has page scripts that do not parse, so an answer entered on it would be lost: %s\n' "$artifact" >&2
    printf '%s\n' "$verdict" | awk -F'\t' '$1 == "FAIL" { printf "  %s (%s): %s\n", $2, $3, $4 }' >&2
    printf 'fix: never paste text into an inline handler string; build the handler with addEventListener or read the text from a data attribute\n' >&2
    return 1
  fi
  printf '%s\n' "$verdict" | awk -F'\t' '$1 == "SUMMARY" { printf "check: ok handlers=%s scripts=%s\n", $2, $3 }'
  # Parsing cleanly does not make a form safe: a handler that never cancels its
  # own submit still navigates the frame. The guard asset turns that into a
  # visible failure instead of a lost answer.
  printf '%s\n' "$verdict" | awk -F'\t' '$1 == "SUMMARY" && $5 > 0 && $6 == 0 { exit 1 }' || \
    printf 'warning: this board has inline form handlers but no data-fm-lavish-form-guard script; a form that fails to cancel its own submit would lose the answer silently. Add .agents/skills/bearings/assets/lavish-form-guard.html: %s\n' "$artifact" >&2
  return 0
}

cmd_arm() {
  local artifact='' task='' reply_file='' id real owner listening
  local -a listener=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for)
        [ "$#" -ge 2 ] || usage
        task=$2
        shift 2
        ;;
      --agent-reply-file)
        [ "$#" -ge 2 ] || usage
        reply_file=$2
        shift 2
        ;;
      --*) usage ;;
      *)
        [ -z "$artifact" ] || usage
        artifact=$1
        shift
        ;;
    esac
  done
  [ -n "$artifact" ] || usage
  [ -z "$reply_file" ] || [ -n "$task" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  poll_retry_delay >/dev/null
  id=$(cmd_source_id "$artifact") || exit 1
  # Check the listener's physical file before registration, including alias arms.
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  cmd_check "$real" >/dev/null || exit 1
  listener=("$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real")
  [ -z "$reply_file" ] || listener+=(--agent-reply-file "$reply_file")
  if [ -n "$task" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register-task lavish "$id" "$task" -- \
      "${listener[@]}" || exit 1
  else
    # This adapter's own listener command, which runs the plain blocking form
    # with no --timeout-ms so completion is a server event, and absorbs only
    # the exact transient interruption.
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" \
      -- "${listener[@]}" || exit 1
  fi
  # Registration is not a running listener. Readiness is the process-event
  # owner's evidence for this generation; a miss retires a source that never
  # started so arm does not leave it registered.
  listening=0
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$id" || listening=$?
  if [ "$listening" -eq 3 ]; then
    printf 'still-listening: %s\n' "$id"
    printf 'artifact: %s\n' "$real"
    [ -z "$task" ] || printf 'owner-task: %s\n' "$task"
    printf 'note: an earlier listener is still live and serving this board; this registration takes effect only after the source is retired and armed again\n'
    exit 0
  fi
  if [ "$listening" -ne 0 ]; then
    owner=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
      | awk -v id="$id" '$1 == id { print $3; exit }')
    case "$owner" in
      live|orphaned|task:*/listening|task:*/round-open) ;;
      *) FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" retire "$id" >/dev/null 2>&1 || true ;;
    esac
    exit 1
  fi
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
  [ -z "$task" ] || printf 'owner-task: %s\n' "$task"
}

cmd_deliver_reply() {
  [ "$#" -eq 4 ] && [ "$1" = poll ] && [ "$3" = --agent-reply-file ] || usage
  lavish_reply_compatible || exit 3
  apply_session_host "$2" \
    || die "cannot resolve the board server from its Lavish session: $2"
  post_lavish_reply "$2" "$4"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# The bounded quiet retry described in the header. The bound is a constant
# because it is a property of the transient response, not an operator choice;
# only the delay takes an override, so a test can exercise the real bound
# without waiting it out.
POLL_RETRY_LIMIT=12
POLL_RETRY_DELAY_DEFAULT=5
POLL_RETRY_DELAY_MIN=1
POLL_RETRY_DELAY_MAX=60

# Exit 10 only for the exact interruption, and nothing else. The whole response
# must be one of its two published forms with those exact bytes: the bare
# two-line form, or that form followed by the one help footer lavish-axi 0.1.79
# generates for it. Whitespace variants, any other help text, a longer response
# that merely opens with them, and any other SERVER_ERROR are genuine errors
# this adapter must never swallow.
poll_response_filter() {  # <response-file>
  perl -e '
    use strict;
    use warnings;
    my ($stage) = @ARGV;
    my $bare = "error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n";
    # The bare form is a prefix of the footer form, so one comparison against
    # the footer form tracks a candidate for either.
    my $footer = $bare
      . "help[2]: Run `lavish-axi server --verbose` or inspect `~/.lavish-axi/server.log`"
      . " (`LAVISH_AXI_STATE_DIR/server.log` when set) for server startup or crash diagnostics,"
      . "Re-run the last `lavish-axi poll <html-file>` command after the server is healthy\n";
    open my $staged, ">", $stage or exit 2;
    binmode STDIN;
    binmode STDOUT;
    binmode $staged;
    my ($candidate, $streaming) = ("", 0);
    sub write_all {
      my ($handle, $bytes) = @_;
      my $offset = 0;
      while ($offset < length $bytes) {
        my $written = syswrite $handle, $bytes, length($bytes) - $offset, $offset;
        exit 2 unless defined $written;
        $offset += $written;
      }
    }
    while (1) {
      my $count = sysread STDIN, my $chunk, 65536;
      exit 2 unless defined $count;
      last if $count == 0;
      if ($streaming) {
        write_all(*STDOUT, $chunk);
        next;
      }
      # Stage through the first byte that leaves the footer form, and no further.
      my $seen = $candidate . $chunk;
      my $span = length($seen) < length($footer) ? length($seen) : length($footer);
      (substr($seen, 0, $span) ^ substr($footer, 0, $span)) =~ /^(\0*)/;
      my $same = length $1;
      my $keep = $same < length($seen) ? $same + 1 : $same;
      write_all($staged, substr($seen, length($candidate), $keep - length($candidate)));
      if ($same == length($seen)) {
        $candidate = $seen;
      } else {
        write_all(*STDOUT, $seen);
        $streaming = 1;
      }
    }
    exit 10 if !$streaming && ($candidate eq $bare || $candidate eq $footer);
    write_all(*STDOUT, $candidate) unless $streaming;
  ' "$1"
}

# Minimum seconds between retry attempt starts. FM_LAVISH_POLL_RETRY_DELAY is a
# bounded test override; a malformed or out-of-range value is refused rather than quietly
# rounded, because silently changing a retry cadence is how a bound stops
# meaning anything.
poll_retry_delay() {
  local delay=${FM_LAVISH_POLL_RETRY_DELAY-}
  if [ -z "$delay" ]; then
    printf '%s\n' "$POLL_RETRY_DELAY_DEFAULT"
    return 0
  fi
  case "$delay" in
    *[!0-9]*) die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $delay" ;;
  esac
  [ "$delay" -ge "$POLL_RETRY_DELAY_MIN" ] && [ "$delay" -le "$POLL_RETRY_DELAY_MAX" ] \
    || die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $delay"
  printf '%s\n' "$delay"
}

poll_iteration_started() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf "%.6f\\n", clock_gettime(CLOCK_MONOTONIC)'
}

poll_iteration_floor_wait() {
  perl -MTime::HiRes=clock_gettime,sleep,CLOCK_MONOTONIC -e '
    my ($started, $floor) = @ARGV;
    my $remaining = $floor - (clock_gettime(CLOCK_MONOTONIC) - $started);
    sleep($remaining) if $remaining > 0;
  ' "$1" "$2"
}

cmd_poll() {
  local artifact=${1-} delay attempt=0 response cleanup_command rc filter_rc iteration_started
  local pipeline_status reply_file=''
  local reply_text='' reply_pending=0 store_attempt=0
  [ -n "$artifact" ] || usage
  if [ "$#" -eq 3 ] && [ "${2-}" = --agent-reply-file ]; then
    reply_file=$3
  elif [ "$#" -ne 1 ]; then
    usage
  fi
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  delay=$(poll_retry_delay) || exit 1
  response=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-poll.XXXXXX") || die "cannot stage the poll response"
  printf -v cleanup_command 'rm -f -- %q' "$response"
  # shellcheck disable=SC2064 # $cleanup_command must expand now, while the staged path is still set.
  trap "$cleanup_command" EXIT
  # Retirement stops this listener by signalling its process group, and bash runs
  # no EXIT trap for an uncaught signal, so each one cleans up the staged
  # response and then re-raises itself with the default disposition, leaving the
  # process dying exactly as the runner expects.
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064 # Same reason: expand now, while both are set.
    trap "$cleanup_command; trap - $signal; kill -$signal $$" "$signal"
  done
  while :; do
    iteration_started=$(poll_iteration_started) || die "cannot start the poll rate governor"
    [ -f "$artifact" ] && [ ! -L "$artifact" ] && [ -r "$artifact" ] \
      || die "artifact is no longer a readable file: $artifact"
    apply_session_host "$artifact"
    case "$?" in
      0) ;;
      3)
        printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n'
        return 1
        ;;
      *)
        [ "$store_attempt" -lt "$POLL_RETRY_LIMIT" ] \
          || die "cannot resolve the board server from its Lavish session: $artifact"
        store_attempt=$((store_attempt + 1))
        poll_iteration_floor_wait "$iteration_started" "$delay" \
          || die "cannot enforce the poll rate governor"
        continue
        ;;
    esac
    # Newer Lavish builds expose a one-shot reply command whose success is the
    # server's acceptance receipt. Consume the staged file only after that
    # confirmation; older compatible builds retain the published poll reply
    # behavior and its best-effort delivery boundary.
    if [ -f "$reply_file" ] && [ ! -L "$reply_file" ]; then
      if lavish_reply_compatible; then
        post_lavish_reply "$artifact" "$reply_file"
        rm -f -- "$reply_file" || die "cannot consume agent reply file: $reply_file"
      else
        reply_text=$(cat -- "$reply_file") \
          || die "cannot read agent reply file: $reply_file"
        rm -f -- "$reply_file" || die "cannot consume agent reply file: $reply_file"
        reply_pending=1
      fi
    fi
    if [ "$reply_pending" -eq 1 ]; then
      lavish-axi poll "$artifact" --agent-reply "$reply_text" | poll_response_filter "$response"
    else
      lavish-axi poll "$artifact" | poll_response_filter "$response"
    fi
    pipeline_status=("${PIPESTATUS[@]}")
    reply_pending=0
    rc=${pipeline_status[0]}
    filter_rc=${pipeline_status[1]}
    case "$filter_rc" in
      0) break ;;
      10)
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          poll_iteration_floor_wait "$iteration_started" "$delay" \
            || die "cannot enforce the poll rate governor"
        else
          cat -- "$response"
          break
        fi
        ;;
      *) die "cannot classify the poll response" ;;
    esac
  done
  # A blocking poll killed by a signal before it printed anything delivered
  # nothing, and Lavish keeps the feedback queued, so this is the runner's
  # existing poll-again exit rather than a failed read awaiting reconciliation.
  # A signal to this listener itself never reaches here: the traps above re-raise it.
  if [ "$rc" -gt 128 ] && [ ! -s "$response" ]; then
    return 75
  fi
  return "$rc"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback)            printf 'feedback\n'; return 0 ;;
    ended)               printf 'ended\n'; return 0 ;;
    waiting)             printf 'waiting\n'; return 0 ;;
    browser_disconnected) printf 'disconnected\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Whether a completed result carries any queued content block at all. The
# published response frames content as a top-level `prompts[N]{...}:` or
# `feedback[N]{...}:` header whose rows are INDENTED, so this anchors on column
# zero: an indented payload line is captain-supplied text and must never be able
# to forge - or, here, to hide behind - a content header. Any recognized block
# is content regardless of its declared count, while a malformed top-level
# prompts or feedback header makes the result indeterminate.
#
# 0 = content present, 1 = provably no content, anything else = the check did
# not complete. The caller must distinguish those three, because "the check
# failed" is never proof that nothing was said.
result_has_queued_content() {  # <result-file>
  awk '
    /^(prompts|feedback)\[[0-9]+\]\{[^}]*\}:[[:space:]]*$/ {
      verdict = "present"
      exit
    }
    /^(prompts|feedback)/ {
      verdict = "indeterminate"
      exit
    }
    END {
      if (verdict == "present") exit 0
      if (verdict == "indeterminate") exit 2
      exit 1
    }
  ' "$1"
}

# Whether a captured result is a routine no-op the runner should record without
# announcing, for the generic runner's silence seam. Lavish's notion of "nothing
# was said" lives here and nowhere else: an ended session carrying no queued
# content block is a board the captain closed without saying anything, and the
# handler learns nothing from being told. Anything else - a real answer, a
# missing or waiting session, an unreadable result - is announced.
cmd_silent() {
  local file=${1-} content_rc
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = disconnected ] && return 0
  [ "$(cmd_classify "$file")" = ended ] || return 1
  result_has_queued_content "$file"
  content_rc=$?
  # Only a completed check that proved the result carries nothing declares
  # silence; a check that could not complete announces, like every other
  # uncertainty here.
  [ "$content_rc" -eq 1 ]
}

# Print `key<TAB>answer<TAB>label[<TAB>mode]` for each non-reconcile structured choice the
# captain submitted in a captured result; the optional mode column relays the
# card's declared close mode (`done` or `release`) to the keyed-answer intake. The published response frames queued feedback as
# a `prompts[N]{field,...}:` header followed by exactly N indented CSV rows whose
# quoted fields carry JSON-style escapes, so this reads the declared field ORDER
# rather than assuming a fixed column, and takes only rows whose `tag` field is
# `choice`. A freeform `message` row is captain prose and is deliberately never a
# source of decision keys. docs/captain-hold-lifecycle.md (How a board selection
# creates a request) owns the versioned and legacy context contract. Resolve the
# latest valid row before filtering either output so legacy Reconcile cannot
# revive an earlier answer or request.
# The question cap is 128 so any task id fits, including the long legacy
# `<origin>-decision-<key>` identities pre-collapse decks still carry; the
# security property is the slug SHAPE, which is unchanged.
cmd_choice_rows() {
  local selection=$1 file=${2-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($selection, $path) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^prompts\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    my %seen;
    my @choices;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          my $v = $1;
          $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
          push @vals, $v;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      my $data = eval { decode_json($ctx) };
      next unless ref($data) eq "HASH";
      my ($key, $selected, $note, $answer, $legacy);
      if (defined($data->{schema}) && !ref($data->{schema})
          && $data->{schema} eq "fm-bearings-answer.v1") {
        $key = $data->{question};
        $selected = $data->{selection};
        $note = $data->{note};
        next if !defined($key) || ref($key) || !defined($selected) || ref($selected)
          || !defined($note) || ref($note);
        next unless $selected eq "" || $selected =~ /\A[A-Za-z0-9._-]{1,128}\z/;
        next unless length($note) <= 512;
        next unless length($selected) || length($note);
        $answer = length($selected) ? $selected : $note;
        $legacy = 0;
      # Legacy bookkeeping is not evidence of a schema version. A note enriches
      # the label, never the selected answer.
      } elsif (!exists($data->{schema}) && !exists($data->{selection})) {
        $key = $data->{question};
        $answer = exists($data->{answer}) ? $data->{answer} : $data->{choice};
        $note = defined($data->{note}) ? $data->{note} : "";
        next if !defined($key) || ref($key) || !defined($answer) || ref($answer) || ref($note);
        next unless length($answer) && length($answer) <= 512;
        $selected = "";
        $legacy = 1;
      } else {
        next;
      }
      next unless $key =~ /\A[A-Za-z0-9._-]{1,128}\z/;
      my $mode = "";
      if (exists $data->{close}) {
        next if !defined($data->{close}) || ref($data->{close})
          || ($data->{close} ne "done" && $data->{close} ne "release");
        $mode = $data->{close};
      }
      my $label = defined $f{text} ? $f{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $note, $label);
      if ($legacy && length $note && index($label, $note) < 0) {
        $label = length($label) ? "$label - $note" : $note;
      }
      $label = substr($label, 0, 512);
      if (defined $seen{$key}) { $choices[$seen{$key}] = undef }
      $seen{$key} = scalar @choices;
      push @choices, {
        key => $key, selection => $selected, note => $note, legacy => $legacy,
        answer => $answer, label => $label, mode => $mode
      };
    }
    for my $choice (grep { defined } @choices) {
      next if $choice->{legacy} && ($choice->{answer} eq "reconcile"
        || index($choice->{answer}, "reconcile - ") == 0);
      if ($selection eq "reconciles") {
        next if $choice->{legacy};
        if ($choice->{selection} eq "reconcile") {
          print length($choice->{note})
            ? "$choice->{key}\t$choice->{note}\n"
            : "$choice->{key}\n";
        }
        next;
      }
      next if $choice->{selection} eq "reconcile";
      print length $choice->{mode}
        ? "$choice->{key}\t$choice->{answer}\t$choice->{label}\t$choice->{mode}\n"
        : "$choice->{key}\t$choice->{answer}\t$choice->{label}\n";
    }
  ' "$selection" "$file"
}

cmd_answers() { cmd_choice_rows answers "$@"; }
cmd_reconciles() { cmd_choice_rows reconciles "$@"; }

# Present one already-captured result for a handler. Body lines are prefixed
# so a captain-supplied string cannot forge a section label. A freeform message
# is printed before the count line and before any annotation, because that is
# the field a truncated grep of the raw capture historically dropped.
# A non-choice annotation that carries a freeform `prompt` prints that comment
# as its own field; a selector must not hide the typed words, even when the
# comment matches the captured element text. Choice rows keep Context data
# out of that field. A pure annotation has no prompt.
cmd_read() {
  local file=${1-} lifecycle session_ended
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  lifecycle=$(cmd_classify "$file")
  session_ended=$(session_field "$file" session_ended)
  perl -e '
    use strict; use warnings;
    my ($path, $lifecycle, $session_ended) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^(?:prompts|feedback)\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if defined($want) && @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    $want = 0 unless defined $want;
    my @parsed;
    my $malformed = 0;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          push @vals, $1;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      if (@vals > @fields) {
        my ($preserve) = grep { $fields[$_] eq "prompt" } 0 .. $#fields;
        ($preserve) = grep { $fields[$_] eq "text" } 0 .. $#fields unless defined $preserve;
        if (defined $preserve) {
          my $count = @vals - @fields + 1;
          my @parts = splice @vals, $preserve, $count;
          splice @vals, $preserve, 0, join(",", @parts);
        }
      }
      if (@vals != @fields) {
        $malformed++;
        next;
      }
      s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge for @vals;
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      push @parsed, \%f;
    }
    my $presented = scalar @parsed;
    my $complete = ($presented == $want && !$malformed) ? "yes" : "no";
    my @messages;
    my @annotations;
    for my $f (@parsed) {
      my $tag = defined $f->{tag} ? $f->{tag} : "";
      if ($tag eq "message") {
        push @messages, $f;
      } else {
        push @annotations, $f;
      }
    }
    sub emit_body {
      my ($text) = @_;
      $text = "" unless defined $text;
      $text =~ s/\r\n/\n/g;
      $text =~ s/\r/\n/g;
      my @lines = split /\n/, $text, -1;
      pop @lines if @lines && $lines[-1] eq "";
      return if !@lines || (@lines == 1 && $lines[0] eq "");
      print "| $_\n" for @lines;
    }
    my $ended = $session_ended =~ /^(?:true|True|TRUE)$/;
    if (@messages) {
      my $message_label = $ended ? "SESSION-ENDING MESSAGE" : "CAPTAIN MESSAGE";
      print "$message_label\n";
      for my $i (0 .. $#messages) {
        print "$message_label PART ", ($i + 1), " of ", scalar(@messages), "\n" if @messages > 1;
        my $body = defined $messages[$i]{prompt} && length $messages[$i]{prompt}
          ? $messages[$i]{prompt}
          : (defined $messages[$i]{text} ? $messages[$i]{text} : "");
        emit_body($body);
      }
      print "END $message_label\n";
    } else {
      print "SESSION-ENDING MESSAGE: (none)\n";
    }
    print "\n";
    print "declared_items: $want\n";
    print "presented_items: $presented\n";
    print "malformed_items: $malformed\n";
    print "complete: $complete\n";
    print "lifecycle: $lifecycle\n";
    print "session_ended: ", (length $session_ended ? $session_ended : "(unset)"), "\n";
    print "annotation_count: ", scalar(@annotations), "\n";
    my $message_count_key = $ended ? "session_ending_message_count" : "captain_message_count";
    print "$message_count_key: ", scalar(@messages), "\n";
    print "\n";
    if (@annotations) {
      print "ANNOTATIONS\n";
      my $n = 0;
      for my $f (@annotations) {
        $n++;
        my $uid = defined $f->{uid} ? $f->{uid} : "";
        my $selector = defined $f->{selector} ? $f->{selector} : "";
        my $tag = defined $f->{tag} ? $f->{tag} : "";
        print "ANNOTATION $n of ", scalar(@annotations), "\n";
        print "element_uid: $uid\n";
        print "element_selector: $selector\n";
        print "tag: $tag\n";
        print "text:\n";
        my $elem = defined $f->{text} ? $f->{text} : "";
        my $comment = defined $f->{prompt} ? $f->{prompt} : "";
        my $body = length $elem ? $elem : $comment;
        emit_body($body);
        if ($tag ne "choice" && length $comment) {
          print "prompt:\n";
          emit_body($comment);
        }
      }
      print "END ANNOTATIONS\n";
    } else {
      print "ANNOTATIONS: (none)\n";
    }
    print "END LAVISH RESULT ($presented of $want)\n";
  ' "$file" "$lifecycle" "$session_ended"
}

# --- sweep: retire listeners whose boards are finished -----------------------
# The header owns the rules. This section only reads facts and applies them; the
# generic `retire` in bin/fm-procevent.sh stays the one place a registration and
# its runner are actually removed.
BOARD_IDLE_HOURS_DEFAULT=48
BOARD_IDLE_HOURS_MAX=8760

board_idle_seconds() {
  local value=${FM_BOARD_LISTENER_IDLE_HOURS-$BOARD_IDLE_HOURS_DEFAULT}
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  value=$((10#$value))
  [ "$value" -ge 1 ] && [ "$value" -le "$BOARD_IDLE_HOURS_MAX" ] || return 1
  printf '%s\n' $((value * 3600))
}

# `sessions` is "unknown" when Lavish's store cannot be read, so an unreadable
# store keeps every board instead of reading as "no session".
sweep_facts() {  # <state-dir> <lavish-store>
  local inbox_facts
  inbox_facts=$(fm_procevent_inbox_facts "$1" "${@:3}") || return 1
  perl -MJSON::PP -MCwd=realpath -MErrno=ENOENT -MEncode=decode,FB_DEFAULT -MTime::Local=timegm -e '
    use strict; use warnings;
    my ($inbox_facts, $store) = @ARGV;
    my (%by, $store_ok, %inbox);
    for my $row (split /\n/, $inbox_facts) {
      my ($id, @facts) = split /\t/, $row, 4;
      $inbox{$id} = \@facts;
    }
    if (open my $sf, "<", $store) {
      local $/;
      local $! = 0;
      my $json = <$sf>;
      my $read_ok = !$!;
      my $close_ok = close $sf;
      my $doc = eval { decode_json($json) };
      if ($read_ok && $close_ok && ref($doc) eq "HASH" && ref($doc->{sessions}) eq "HASH") {
        $store_ok = 1;
        for my $s (values %{$doc->{sessions}}) {
          push @{$by{$s->{file}}}, $s if ref($s) eq "HASH" && defined $s->{file} && !ref($s->{file});
        }
      }
    }
    sub unescape {
      my ($v) = @_;
      $v =~ s/&#[xX]([0-9a-fA-F]+);/chr(hex($1))/ge;
      $v =~ s/&#([0-9]+);/chr($1)/ge;
      $v =~ s/&quot;/"/g;
      $v =~ s/&apos;/\x27/g;
      $v =~ s/&lt;/</g;
      $v =~ s/&gt;/>/g;
      $v =~ s/&amp;/&/g;
      return $v;
    }
    while (my $line = <STDIN>) {
      chomp $line;
      my ($id, $art) = split /\t/, $line, 2;
      next unless defined $art;
      my @stat = stat $art;
      my $file_state = @stat ? (-f _ && defined realpath($art) ? "present" : "unknown")
        : ($! == ENOENT ? "missing" : "unknown");
      my ($sessions, $status, $pending, @keys) = ("unknown", "", 0);
      my $keys_unknown = 0;
      my ($activity, $captured, $evidence) = @{$inbox{$id} // [0, 0, "inbox evidence cannot be read"]};
      $evidence = "the board file cannot be checked" if $file_state eq "unknown";
      if ($file_state eq "present") {
        my $t = $stat[9];
        $activity = $t if $t > $activity;
        if (open my $in, "<:raw", $art) {
          local $/;
          local $! = 0;
          my $html = <$in>;
          my $read_ok = !$!;
          my $close_ok = close $in;
          if ($read_ok && $close_ok) {
            $html //= "";
            my %seen;
            $html =~ s{<!--.*?(?:-->|\z)}{}gs;
            while ($html =~ m{<([A-Za-z][\w:-]*)(?=[\s/>])}g) {
              my $tag = lc $1;
              my %attr;
              while ($html =~ m{\G\s*([^\s"\x27<>/=]+)(?:\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\s"\x27=<>`]+)))?}gc) {
                my $name = lc $1;
                $attr{$name} //= unescape($2 // $3 // $4 // "");
              }
              if ($html !~ m{\G\s*/?>}gc
                  || $tag =~ /\A(?:script|iframe|object|embed|template)\z/
                  || grep { /\Aon/i || lc($_) eq "srcdoc" || $attr{$_} =~ /\A\s*javascript:/i } keys %attr) {
                $keys_unknown = 1;
                last;
              }
              if (!exists $attr{"data-lavish-question"}) {
                $keys_unknown = 1 if $tag eq "form";
                next;
              }
              my $k = $attr{"data-lavish-question"};
              if ($k !~ /\A[A-Za-z0-9._-]{1,128}\z/) {
                $keys_unknown = 1;
                last;
              }
              push @keys, $k unless $seen{$k}++;
            }
            $keys_unknown = 1 unless @keys;
          } else {
            $evidence = "the board file cannot be read";
          }
        } elsif ($! == ENOENT) {
          $file_state = "missing";
        } else {
          $evidence = "the board file cannot be opened";
        }
      }
      if ($store_ok) {
        my $list = $by{decode("UTF-8", $art, FB_DEFAULT)} // [];
        $sessions = @$list > 1 ? "unknown" : scalar @$list;
        if (@$list == 1) {
          my $s = $list->[0];
          $status = $s->{status} // "";
          $pending = $s->{pending_prompts} // 0;
          $pending = 0 unless $pending =~ /\A[0-9]+\z/;
          if (($s->{updated_at} // "") =~ /\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/) {
            my $t = eval { timegm($6, $5, $4, $3, $2 - 1, $1) } // 0;
            $activity = $t if $t > $activity;
          }
        }
      }
      print join("\t", $id, $art, $file_state, $sessions, $status || "-", $pending, $activity, $keys_unknown ? "?" : (join(",", @keys) || "-"), $captured, $evidence), "\n";
    }
  ' "$inbox_facts" "$2"
}

sweep_cards_closed() {
  local source=$1 keys=$2 key rc IFS=,
  if [ "$keys" = '?' ] || [ "$keys" = '-' ] || [ -z "$keys" ]; then
    reason="the board's complete card-key set cannot be established"
    return 1
  fi
  for key in $keys; do
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" open-bound "$source" "$key" \
      >/dev/null 2>&1 </dev/null
    rc=$?
    if [ "$rc" -ne 1 ]; then
      reason="card $key is an open captain call or cannot be checked"
      return 1
    fi
  done
  return 0
}

cmd_sweep() {
  local dry=0 idle state reg store now rec id adapter kind artifact standing line n in_argv argv_poll
  local facts file_state sessions status queued activity keys captured evidence reason verdict out identity current_identity
  local retired=0 kept=0 idx
  local -a ids=() kinds=() identities=()
  case "${1-}" in
    '') ;;
    --dry-run) dry=1; shift ;;
    *) usage ;;
  esac
  [ "$#" -eq 0 ] || usage
  idle=$(board_idle_seconds) \
    || die "FM_BOARD_LISTENER_IDLE_HOURS must be whole hours from 1 to $BOARD_IDLE_HOURS_MAX"
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  reg=$(fm_procevent_registry_dir "$state")
  store=${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json
  now=$(date +%s)
  standing=$(perl -MCwd=realpath -MFile::Basename=dirname,basename -e '
    my $home = realpath($ARGV[0]) // exit 1;
    my $p = "$home/.lavish/bearings-board.html";
    if (defined(my $real = realpath($p))) { print $real; exit }
    my $hops = 0;
    while (-l $p) {
      if ($hops++ >= 40) { print "?"; exit }
      my $target = readlink($p);
      if (!defined $target) { print "?"; exit }
      $p = $target =~ m{\A/} ? $target : dirname($p) . "/$target";
    }
    my $dir = realpath(dirname($p));
    print defined($dir) ? "$dir/" . basename($p) : $p;
  ' "$FM_HOME" 2>/dev/null || true)

  facts=''
  for rec in "$reg"/lavish-*.source; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    id=${rec##*/}; id=${id%.source}
    fm_procevent_source_id_valid "$id" || continue
    identity=$(fm_pr_file_identity "$rec" 2>/dev/null) || continue
    adapter=''; kind=plain; argv_poll=''; artifact=''; n=0; in_argv=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$in_argv" = 1 ]; then
        n=$((n + 1))
        [ "$n" -ne 2 ] || argv_poll=$line
        [ "$n" -ne 3 ] || artifact=$line
        continue
      fi
      case "$line" in
        adapter=*) adapter=${line#adapter=} ;;
        kind=*) kind=${line#kind=} ;;
        argv:) in_argv=1 ;;
      esac
    done < "$rec"
    current_identity=$(fm_pr_file_identity "$rec" 2>/dev/null) || continue
    [ "$current_identity" = "$identity" ] || continue
    [ "$adapter" = lavish ] && [ "$argv_poll" = poll ] && [ -n "$artifact" ] || continue
    ids+=("$id"); kinds+=("$kind"); identities+=("$identity")
    facts="$facts$id"$'\t'"$artifact"$'\n'
  done
  if [ "${#ids[@]}" -eq 0 ]; then
    printf 'sweep: retired=0 kept=0\n'
    return 0
  fi
  facts=$(printf '%s' "$facts" | sweep_facts "$state" "$store" "${ids[@]}") || die "cannot read the Lavish board facts"

  while IFS=$'\t' read -r id artifact file_state sessions status queued activity keys captured evidence; do
    [ -n "$id" ] || continue
    kind=plain; identity=''
    for idx in "${!ids[@]}"; do
      [ "${ids[$idx]}" = "$id" ] && { kind=${kinds[$idx]}; identity=${identities[$idx]}; break; }
    done
    verdict=keep
    if [ "$evidence" != - ]; then
      reason=$evidence
    elif [ "$standing" = '?' ]; then
      reason='the standing Bearings board path cannot be resolved'
    elif [ -n "$standing" ] && [ "$artifact" = "$standing" ]; then
      reason='the standing Bearings board'
    elif [ "$sessions" = unknown ]; then
      reason='Lavish session evidence cannot be read unambiguously'
    elif [ "$status" = feedback ] || [ "$queued" -gt 0 ]; then
      reason='Lavish holds queued feedback for the board'
    elif [ "$kind" = task-owned ]; then
      reason='owned by a worker task'
    elif [ "$file_state" = missing ]; then
      verdict=retire; reason='the board file is gone'
    elif [ "$sessions" != 0 ] && [ "$status" != ended ] && [ $((now - activity)) -lt "$idle" ]; then
      reason="active within the last $((idle / 3600)) hours"
    else
      if [ "$sessions" = 0 ]; then
        reason='Lavish holds no session for the board'
      elif [ "$status" = ended ]; then
        reason='the Lavish session has ended'
      else
        reason="idle for $(((now - activity) / 3600)) hours with no open captain call"
      fi
      if sweep_cards_closed "$id" "$keys"; then
        verdict=retire
      fi
    fi
    if [ "$verdict" = retire ] && [ "$captured" = 1 ]; then
      verdict=keep; reason='a captured round of the board is unacknowledged'
    fi
    if [ "$verdict" = retire ] && [ "$dry" = 0 ]; then
      if ! out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" retire "$id" --if-identity "$identity" 2>&1 </dev/null); then
        verdict=keep
        reason="retire refused: ${out%%$'\n'*}"
      fi
    fi
    if [ "$verdict" = retire ]; then
      retired=$((retired + 1))
      if [ "$dry" = 1 ]; then
        printf 'would-retire: %s %s - %s\n' "$id" "$artifact" "$reason"
      else
        printf 'retired: %s %s - %s\n' "$id" "$artifact" "$reason"
      fi
    else
      kept=$((kept + 1))
      printf 'kept: %s %s - %s\n' "$id" "$artifact" "$reason"
    fi
  done <<SWEEP_FACTS
$facts
SWEEP_FACTS
  if [ "$dry" = 1 ]; then
    printf 'sweep: would-retire=%s kept=%s\n' "$retired" "$kept"
  else
    printf 'sweep: retired=%s kept=%s\n' "$retired" "$kept"
  fi
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  sweep)     shift; cmd_sweep "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  deliver-reply) shift; cmd_deliver_reply "$@" ;;
  check)     shift; cmd_check "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  relisten)
    shift
    [ "$#" -le 1 ] || usage
    if [ -n "${1-}" ] && [ -s "$1" ]; then
      case "$(cmd_classify "$1")" in
        feedback) exit 0 ;;
        disconnected|waiting) ;;
        *) exit 1 ;;
      esac
    fi
    delay=$(poll_retry_delay) || exit 1
    sleep "$delay"
    ;;
  silent)    shift; cmd_silent "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  reconciles) shift; cmd_reconciles "$@" ;;
  read)      shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
