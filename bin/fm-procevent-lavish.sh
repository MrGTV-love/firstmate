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
#   fm-procevent-lavish.sh poll <artifact.html> [--agent-reply-file <path>]
#   fm-procevent-lavish.sh check <artifact.html>
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, disconnected, missing, or unknown.
# read       Print a structured presentation of one already-captured result so a
#            handler consumes every queued item without grepping the raw file.
#            It is read-only over the capture: it does not arm, poll, or change
#            what Lavish delivered. The freeform message (tag=message) is its
#            own labeled field, printed first and distinct from per-element
#            annotations; it is labeled SESSION-ENDING MESSAGE only when the
#            session ended. Declared and presented item counts,
#            plus a completeness verdict, follow before all annotations so a
#            partial read is obvious. Each annotation retains its element uid,
#            selector, tag, and text. A non-choice freeform comment (`prompt`)
#            is printed as its own field even when a selector is also present
#            and even when that comment matches the element text, so typed
#            words are never dropped. Choice Context data is not a comment.
#            Captain-supplied body lines are visibly prefixed so they cannot
#            forge structural labels. Empty message and annotation sections
#            are reported explicitly.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It runs the published blocking poll
#            and prints its response verbatim, absorbing only the one exact
#            transient interruption described below. A task-owned arm consumes
#            its staged reply file once - reading and removing it before the
#            poll - and hands the contents to the published `--agent-reply`
#            argument; later retries poll without that reply. That post is best
#            effort: a crash while consuming drops that one round's reply
#            instead of posting it twice. See the note at the consume site.
# check      Compile, without running, every inline event handler and inline
#            classic script in the board and exit 1 naming each one that does not
#            parse. `arm` runs it first and refuses such a board. The defect it
#            guards is a form whose inline onsubmit holds text pasted into a
#            quoted JavaScript string (an apostrophe in a decision title ends
#            the string): the handler fails to parse, the browser submits the
#            form natively, the artifact frame lands on Lavish's 409 "no longer
#            current" page, and no reload can repair it because the file itself
#            is broken. Build handlers with addEventListener or read their text
#            from data attributes, and run `check` before opening a board.
#            It also warns, without failing, when a board has inline onsubmit
#            handlers and lacks the guard in
#            .agents/skills/bearings/assets/lavish-form-guard.html, which turns a
#            form that fails to cancel its own submit into a visible error and an
#            error prompt for the agent instead of a silent loss.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
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
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# and how to read a completed result. Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
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
# An unreadable or missing session stops before the staged reply is consumed.
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
# It wraps ONLY the currently published interface, verified against 0.1.45:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# BOUNDED QUIET RETRY, owned here and nowhere else. A live listener can be cut
# short by the server with exactly this two-line response while the session's
# marks remain available:
#
#   error: Lavish Editor poll response was interrupted
#   code: SERVER_ERROR
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
  local endpoint
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
    !$@ or die "invalid Lavish session store\n";
    ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH"
      or die "invalid Lavish session store\n";
    my @sessions = grep {
      ref($_) eq "HASH" && defined($_->{file}) && $_->{file} eq $real
    } values %{$state->{sessions}};
    @sessions == 1 or die "board must have one saved Lavish session\n";
    my $url = $sessions[0]->{url} // "";
    $url =~ m{\Ahttp://(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):([0-9]+)/session/[0-9a-f]{16}(?:\?[^\s#]*)?\z}
      or die "invalid saved Lavish session URL\n";
    my ($host, $port) = ($1, $2);
    $host =~ s/^\[|\]$//g;
    $host ne "0.0.0.0" && $host ne "::" && $port >= 1 && $port <= 65535
      or die "invalid saved Lavish server address\n";
    print "$host\n$port\n";
  ' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json" "$1") \
    || die "cannot resolve the board server from its Lavish session: $1"
  LAVISH_AXI_HOST=${endpoint%$'\n'*}
  LAVISH_AXI_PORT=${endpoint##*$'\n'}
  export LAVISH_AXI_HOST LAVISH_AXI_PORT
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

# Compile, never run, every inline event handler and inline classic script the
# board carries. A handler that fails to parse is not a no-op in a browser: the
# form it sits on submits natively, which navigates the sandboxed artifact frame
# to a URL with no load token, and Lavish answers that with a 409 "no longer
# current" page. Reloading cannot repair it, and the answer never reaches the
# poll. The syntax error is a property of the file, so it is caught here rather
# than discovered by the captain. Handler bodies are compiled as the function
# body a browser wraps them in; a type=module, JSON, or other non-classic script
# is skipped because this check cannot parse it faithfully.
#
# 0 = nothing broken (including a board with nothing to compile), 1 = at least
# one parse failure, printed one per line, anything else = the check could not
# complete, which is never proof the board is sound.
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
    # Inline scripts first, then blank them (keeping their newlines) so script
    # text can never be mistaken for markup by the tag scan below.
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
  # A board whose page scripts do not parse loses every answer entered on it, so
  # it is refused before anything is registered or listening.
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

# Exit 0 only for the exact two-line interruption, and nothing else. The whole
# response must be those two lines with those exact bytes: whitespace variants,
# a longer response that merely opens with them, and any other SERVER_ERROR are
# genuine errors this adapter must never swallow.
poll_response_filter() {  # <response-file>
  perl -e '
    use strict;
    use warnings;
    my ($stage) = @ARGV;
    my $expected = "error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n";
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
      my $room = length($expected) + 1 - length($candidate);
      my $take = length($chunk) < $room ? length($chunk) : $room;
      my $prefix = substr($chunk, 0, $take);
      $candidate .= $prefix;
      write_all($staged, $prefix);
      my $matches_prefix = length($candidate) <= length($expected)
        && substr($expected, 0, length($candidate)) eq $candidate;
      if (!$matches_prefix) {
        write_all(*STDOUT, $candidate);
        write_all(*STDOUT, substr($chunk, $take));
        $streaming = 1;
      }
    }
    exit 10 if !$streaming && $candidate eq $expected;
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
  local reply_text='' reply_pending=0
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
    # Posting a round's reply is BEST EFFORT and deliberately carries no delivery
    # machinery. The staged file is the only record that a reply is owed, so it is
    # consumed HERE - after every non-posting step that could abort this poll has
    # already succeeded - leaving one narrow window: a crash between consuming the
    # file and the call below drops this one round's reply rather than posting it
    # twice. A listener that starts with no staged file simply polls without one.
    # Robust delivery waits on lavish-axi's own exclusive listener; do not add a
    # receipt, retry, or idempotency marker here.
    if [ -f "$reply_file" ] && [ ! -L "$reply_file" ]; then
      reply_text=$(cat -- "$reply_file") \
        || die "cannot read agent reply file: $reply_file"
      rm -f -- "$reply_file" || die "cannot consume agent reply file: $reply_file"
      reply_pending=1
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
# source of decision keys. A row that does not carry both a slug-shaped `question`
# and the versioned `selection` and `note` fields inside its `Context data:` block
# is skipped. A time-limited rollout branch accepts the old question/answer
# shape only for ordinary answers and rejects its bare or annotated reconcile
# values because old rows do not separate the selected option from its note.
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
      # Time-limited compatibility for captures from pre-change boards; remove
      # once no board carrying the old question/answer context can remain armed.
      } elsif (!exists($data->{schema}) && !exists($data->{selection})
          && !exists($data->{note})) {
        $key = $data->{question};
        $answer = $data->{answer};
        next if !defined($key) || ref($key) || !defined($answer) || ref($answer);
        next unless length($answer) && length($answer) <= 512;
        next if $answer eq "reconcile" || index($answer, "reconcile - ") == 0;
        $selected = "";
        $note = "";
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
      $label = substr($label, 0, 512);
      if (defined $seen{$key}) { $choices[$seen{$key}] = undef }
      $seen{$key} = scalar @choices;
      push @choices, {
        key => $key, selection => $selected, note => $note, legacy => $legacy,
        answer => $answer, label => $label, mode => $mode
      };
    }
    for my $choice (grep { defined } @choices) {
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
    if (@messages) {
      my $message_label = $session_ended =~ /^(?:true|True|TRUE)$/
        ? "SESSION-ENDING MESSAGE" : "CAPTAIN MESSAGE";
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
    print "session_ending_message_count: ", scalar(@messages), "\n";
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

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  check)     shift; cmd_check "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  reconciles) shift; cmd_reconciles "$@" ;;
  read)      shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
