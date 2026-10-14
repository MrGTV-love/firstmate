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
#   fm-procevent-lavish.sh orphans [--kill]
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
#            presented item counts, plus a completeness verdict, follow before
#            all annotations so a partial read is obvious. Both TOON table and
#            list collections are accepted. An unparseable collection header
#            (or feedback without one) prints parse_status: unreadable and
#            complete: no, and exits nonzero rather than certifying an empty
#            capture. Each annotation retains its element uid,
#            selector, tag, and text. A non-choice freeform comment (`prompt`)
#            is printed as its own field even when a selector is also present
#            and even when that comment matches the element text, so typed
#            words are never dropped. Choice Context data is not a comment.
#            Captain-supplied body lines are visibly prefixed so they cannot
#            forge structural labels. Empty message and annotation sections
#            are reported explicitly.
# orphans    List leftover Lavish poll processes that no listener owns, one
#            `orphan:` or `kept:` line per process plus an `orphans:` total.
#            Nothing is signalled without --kill, which sends TERM to each listed
#            orphan and prints `killed:` for it. A process is an orphan only when
#            both are proved: it is firstmate's own poll by exact identity - this
#            adapter's `poll` whose pid and start time match the poller record it
#            wrote in this home's registry for that source, or a native
#            `lavish-axi poll <artifact> [--takeover] [--agent-reply <text>]`
#            whose parent is such an adapter - and no live claim's process
#            group contains it. `poll` writes its record at entry
#            and removes it on exit, and each scan first drops records whose
#            process is gone or started at another time, so a reused pid never
#            matches. Anything unproved - an unresolvable artifact, no matching
#            poller record (every poll started before these records existed), a
#            busy source lock, an uncertain claim, or a process whose identity
#            changed before the signal - is kept with its reason. It never
#            retires a registration.
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
#            and prints its response verbatim, absorbing only the exact
#            transient responses described below. A staged reply still
#            present when it starts is posted before the long-poll: through
#            `lavish-axi reply` when supported, otherwise through the legacy
#            best-effort `poll --agent-reply` path. Lavish refuses a held page
#            before it publishes that legacy reply, so a reply refused with
#            LISTENER_ACTIVE is staged again and carried by the takeover, the
#            next quiet retry or the next round. Any other response may follow
#            publication, so that reply is never posted twice.
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
#            seconds before another poll, and consecutive captured waiting
#            rounds double that wait up to POLL_RETRY_DELAY_MAX seconds
#            (waiting_retry_delay). Worker-owned feedback still waits for
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
# second poller was present; it is not a normal idle round. lavish-axi 0.1.79
# refuses that poll with typed `code: LISTENER_ACTIVE` instead: the page is held.
# `poll` then checks every other poll process on the page with the `orphans`
# test. When each is a proved stray, it polls again with `--takeover`, so the
# next answer reaches this listener. Otherwise it displaces nothing: it prints
# the refusal plus `held-page:` and `held-by:` lines naming the page and each
# unproved poll, which `classify` reports as waiting, once per hold. While the
# latest capture is that report, later refusals stay quiet and retry after the
# quiet delay, doubling to POLL_RETRY_DELAY_MAX, under the same runner and claim.
# A LISTENER_REPLACED result means another poll took this listener's page over.
# `classify` reports it as waiting and `terminal` keeps the source armed, so it
# is that hold's one report: later refusals stay quiet with the same back-off,
# and the listener regains the page when the other poll ends.
# browser_disconnected
# means the session remains open and is handled as a silent reconnect wait.
# Before each poll attempt, resolve the artifact's saved URL from Lavish's own
# session store (LAVISH_AXI_STATE_DIR/state.json, default ~/.lavish-axi/state.json)
# and use its host and port. Opening the board writes that URL; polling does not.
# This is a routing lookup before the blocking call, not presence polling or a
# second route record. Ambient/configured addresses must not retarget a reply.
# An unreadable session stops before the staged reply is consumed; a valid
# store with no saved session for the board emits NOT_FOUND for terminal retirement.
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
# Their retried polls then race to auto-start that server, and each loser gets
#
#   error: Lavish Editor server did not start
#   code: SERVER_ERROR
#   help[1]: Run `lavish-axi server --port <port>` to inspect server startup
#
# while the winner's server comes up. With <port> exactly the port this poll
# routes to, that is the same restart. The client prints the same response when
# a live server answers its health probe too slowly, so it takes the
# health-checked start retry described under BOUNDED QUIET RETRY WHILE THE
# SERVER ANSWERS SLOWLY below, which also covers the winner's server coming up.
#
# A supported restart can also return exactly these two lines:
#
#   error: Lavish Editor server connection failed
#   code: SERVER_ERROR
#
# This response, bare or followed by the exact generated help[2] footer above,
# takes the same bounded retry; it does not establish which transport step
# failed. Other connection-error wording or help text remains an unknown error,
# not a reconnect signal.
#
# That is an internal retry, not news, so registering the raw poll made the
# generic runner capture it and wake the whole fleet. `poll` therefore re-runs
# the published poll up to POLL_RETRY_LIMIT times for those exact responses.
# Each quiet retry waits POLL_RETRY_DELAY_DEFAULT monotonic seconds after the
# preceding attempt finishes, so delayed routing or CLI startup cannot buy
# credit for later retries. The match is exact and deliberately narrow: real
# feedback, ended and missing sessions, any other SERVER_ERROR or help text,
# and the same interruption still standing after the bound is spent are all
# printed straight through and captured normally. The retry is a Lavish fact,
# so the generic runner in bin/fm-procevent.sh stays adapter-agnostic.
#
# A blocking poll whose lavish-axi process is killed by a signal before it
# prints anything exits 75, the runner's existing poll-again status, so the same
# runner relistens after the quiet-round delay without awaiting reconciliation.
# Any output, or any other non-zero exit, is handled as before.
#
# BOUNDED QUIET RETRY WHILE THE SERVER ANSWERS SLOWLY, also owned here. The
# published client decides "no server runs" from a health probe with a fixed
# 500 ms timeout (HEALTH_PROBE_TIMEOUT_MS in lavish-axi's dist/cli.mjs, no
# setting), then tries to start one and gives up with exactly this response:
#
#   error: Lavish Editor server did not start
#   code: SERVER_ERROR
#   help[1]: Run `lavish-axi server --port <port>` to inspect server startup
#
# (the two-line form without the help line is accepted too; the port must be the
# board session's port). A server that is alive but answers slower than 500 ms
# produced that response from every armed listener about every 6 minutes on
# 2026-10-10 and woke the fleet each time, while no answer was lost. `poll`
# therefore treats the response as transient while a lavish-axi server still
# answers GET /health on the board session's host and port, and re-runs the
# published poll quietly with exponential backoff, capturing nothing.
#
# The time limits come from measurement, not from a guess. Method: GET /health
# round-trip time, 100 sequential requests 100 to 200 ms apart per condition,
# sorted for p50/p95/p99/max, on an 18-core host whose load average was 45 to 90.
# Healthy servers (a lab server on its own port and state directory, with a copy
# of the real 875 KB session store, 20 live listeners, and 0, 36 or 108 added
# CPU-bound processes; a freshly restarted production server) answered in 1 to
# 5 ms at p50 and 45 ms at worst p99; the slowest single request in about 780
# samples was 257 ms. The production server that caused the incident was
# degraded by its own heap (4.5 GB resident at 197% CPU, fatal "JavaScript heap
# out of memory" in server.log minutes later): p50 679 ms, p95 3.4 s, p99 3.9 s,
# max 4.7 s, and 73 of 100 requests above 500 ms. Host load alone did not slow a
# healthy server, so the fixed 500 ms is right for a healthy one and wrong only
# for a degraded one. Derived limits:
#
#   HEALTH_PROBE_TIMEOUT_SECONDS 10   2x the slowest degraded response (4.7 s)
#                                     and 3.5x the 2.85 s seen in the incident.
#   START_RETRY_LIMIT 15              a 500 ms probe passed 27 of 100 times on the
#                                     degraded server, so a listener that retries
#                                     15 times is still shut out about 0.9% of
#                                     the time (0.73^15); when it is, that is
#                                     persistent degradation worth one wake.
#   backoff 5, 10, 20, 40, then 60 s  about 12 minutes of waits in all, each
#                                     counted after the preceding attempt
#                                     finishes; the base is
#                                     POLL_RETRY_DELAY and the 60 s ceiling keeps
#                                     20 listeners from adding load to a server
#                                     that is already struggling.
#   START_GONE_LIMIT 3                a server that does not answer 3 health
#                                     probes in a row (at least 15 s of backoff)
#                                     is gone, not slow: a fresh server answered
#                                     its first health request 164 to 342 ms
#                                     after launch, and the client already
#                                     waits 5 s for one before giving up.
#
# A server that is gone, and any survivor of the bound, prints the response
# straight through and is captured and announced once, as for the interruption.
# Only that exact response is retried; anything else, including the same words
# with a different port, still surfaces on the first poll.
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
  local artifact='' task='' reply_file='' id real listening
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
  start_retry_cap >/dev/null
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
    # the two exact transient responses.
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" \
      -- "${listener[@]}" || exit 1
  fi
  # Registration is not a running listener. A missed confirmation leaves the
  # registration for the delayed runner or reconcile; cleanup must not wait
  # behind a still-unclaimed runner's source lock after the readiness window.
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
    exit 1
  fi
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
  [ -z "$task" ] || printf 'owner-task: %s\n' "$task"
}

cmd_deliver_reply() {
  [ "$#" -eq 4 ] && [ "$1" = poll ] && [ "$3" = --agent-reply-file ] || usage
  lavish_reply_compatible || exit 3
  apply_session_host "$2" || die "cannot resolve the board server from its Lavish session: $2"
  post_lavish_reply "$2" "$4"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# The bounded quiet retries described in the header. Each bound is a constant
# because it is a property of the transient response, not an operator choice;
# only the delay and the backoff ceiling take overrides, so a test can exercise
# the real bounds without waiting them out.
POLL_RETRY_LIMIT=12
POLL_RETRY_DELAY_DEFAULT=5
POLL_RETRY_DELAY_MIN=1
POLL_RETRY_DELAY_MAX=60
START_RETRY_LIMIT=15
START_GONE_LIMIT=3
HEALTH_PROBE_TIMEOUT_SECONDS=10

# Exit 10 only for the exact restart responses, and 12 only for the exact "server
# did not start" response for this poll's own port, and nothing else. The whole
# response must be one of the forms described above with those exact bytes.
# Whitespace variants, any other help text or port, a longer response that
# merely opens with them, and any other SERVER_ERROR are genuine errors this
# adapter must never swallow. Exit 11 only for a whole LISTENER_ACTIVE refusal:
# one error line, that code line, then only help lines. Its text varies, so it
# is staged whole and printed by the caller when it reports the held page.
poll_response_filter() {  # <response-file>
  perl -e '
    use strict;
    use warnings;
    my ($stage) = @ARGV;
    my $bare = "error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n";
    my $help = "help[2]: Run `lavish-axi server --verbose` or inspect `~/.lavish-axi/server.log`"
      . " (`LAVISH_AXI_STATE_DIR/server.log` when set) for server startup or crash diagnostics,"
      . "Re-run the last `lavish-axi poll <html-file>` command after the server is healthy\n";
    my $connection = "error: Lavish Editor server connection failed\ncode: SERVER_ERROR\n";
    my @forms = ($bare . $help, $connection, $connection . $help);
    my $port = $ENV{LAVISH_AXI_PORT} // "";
    # A restart race or a slow health probe, on the port this poll routes to.
    my $start = "error: Lavish Editor server did not start\ncode: SERVER_ERROR\n";
    my @start_forms = ($start);
    push @start_forms, $start . "help[1]: Run `lavish-axi server --port $port` to inspect server startup\n"
      if $port =~ /\A[0-9]+\z/;
    my $held = qr/\Aerror: [^\n]*\ncode: LISTENER_ACTIVE\n(?:help\[[0-9]+\]: [^\n]*\n)*\z/;
    sub may_be_held {
      my ($seen) = @_;
      my ($head, $code) = ("error: ", "code: LISTENER_ACTIVE\n");
      return 0 if length($seen) > 4096;
      return substr($head, 0, length $seen) eq $seen if length($seen) < length($head);
      return 0 if substr($seen, 0, length $head) ne $head;
      my $newline = index($seen, "\n");
      return 1 if $newline < 0;
      my $rest = substr($seen, $newline + 1);
      return substr($code, 0, length $rest) eq $rest if length($rest) < length($code);
      return substr($rest, 0, length $code) eq $code;
    }
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
      # Stage through the first byte that leaves every form, and no further;
      # a possible LISTENER_ACTIVE refusal is staged whole.
      my $seen = $candidate . $chunk;
      my $same = 0;
      for my $form (@forms, @start_forms) {
        my $span = length($seen) < length($form) ? length($seen) : length($form);
        (substr($seen, 0, $span) ^ substr($form, 0, $span)) =~ /^(\0*)/;
        $same = length $1 if length $1 > $same;
      }
      my $hold = may_be_held($seen);
      my $keep = $hold ? length($seen) : $same < length($seen) ? $same + 1 : $same;
      my $from = length $candidate;
      write_all($staged, substr($seen, $from, $keep - $from)) if $keep > $from;
      if ($same == length($seen) || $hold) {
        $candidate = $seen;
      } else {
        write_all(*STDOUT, $seen);
        $streaming = 1;
      }
    }
    exit 10 if !$streaming && grep { $candidate eq $_ } $bare, @forms;
    exit 11 if !$streaming && $candidate =~ $held;
    exit 12 if !$streaming && grep { $candidate eq $_ } @start_forms;
    write_all(*STDOUT, $candidate) unless $streaming;
  ' "$1"
}

# Minimum quiet-retry delay after the preceding attempt finishes.
# FM_LAVISH_POLL_RETRY_DELAY is a bounded test override; malformed or out-of-range
# values are refused rather than rounded, because silently changing a retry
# cadence is how a bound stops meaning anything.
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

# Delay before polling again after a captured `waiting` round. A second poller
# that stays on the page answers every round with `waiting`, and each one is
# announced, so the delay doubles with each consecutive captured `waiting`
# round, from the quiet-retry delay up to POLL_RETRY_DELAY_MAX. The streak is
# read from the durable captures themselves, so it survives a runner restart
# and ends at the first round that was anything else.
waiting_retry_delay() {  # <result-file> <base-seconds>
  local result=$1 delay=$2 dir id seq previous
  dir=$(dirname -- "$result")
  id=$(fm_procevent_result_source_id "$result")
  seq=$(fm_procevent_result_sequence "$result")
  case "$seq" in ''|*[!0-9]*) printf '%s\n' "$delay"; return 0 ;; esac
  seq=$((10#$seq))
  while [ "$delay" -lt "$POLL_RETRY_DELAY_MAX" ] && [ "$seq" -gt 1 ]; do
    seq=$((seq - 1))
    previous="$dir/$id.$seq.result"
    [ -f "$previous" ] && [ "$(cmd_classify "$previous" 2>/dev/null)" = waiting ] || break
    delay=$((delay * 2))
  done
  [ "$delay" -le "$POLL_RETRY_DELAY_MAX" ] || delay=$POLL_RETRY_DELAY_MAX
  printf '%s\n' "$delay"
}

# Ceiling, in seconds, for the "server did not start" backoff.
# FM_LAVISH_START_RETRY_CAP is a bounded test override with the same refusal rule
# as the delay, so a test can run all START_RETRY_LIMIT retries quickly.
start_retry_cap() {
  local cap=${FM_LAVISH_START_RETRY_CAP-}
  if [ -z "$cap" ]; then
    printf '%s\n' "$POLL_RETRY_DELAY_MAX"
    return 0
  fi
  case "$cap" in
    *[!0-9]*) die "FM_LAVISH_START_RETRY_CAP must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $cap" ;;
  esac
  [ "$cap" -ge "$POLL_RETRY_DELAY_MIN" ] && [ "$cap" -le "$POLL_RETRY_DELAY_MAX" ] \
    || die "FM_LAVISH_START_RETRY_CAP must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $cap"
  printf '%s\n' "$cap"
}

# Seconds to wait after attempt <n> finishes before retry <n>: the delay,
# doubling each time, up to the ceiling.
start_retry_wait() {  # <n> <delay> <cap>
  local wait=$2 i
  for ((i = 1; i < $1; i++)); do
    wait=$((wait * 2))
    [ "$wait" -lt "$3" ] || { wait=$3; break; }
  done
  [ "$wait" -le "$3" ] || wait=$3
  printf '%s\n' "$wait"
}

# Exit 0 when a lavish-axi server answers GET /health on the board session's
# host and port within HEALTH_PROBE_TIMEOUT_SECONDS. Anything else - a refused
# connection, a foreign service, a non-2xx status, an unparsable body, or no
# answer in time - is not an answer.
lavish_server_answers() {  # <host> <port>
  perl -MIO::Socket::IP -MIO::Select -MTime::HiRes=time -MJSON::PP -e '
    use strict;
    use warnings;
    my ($host, $port, $limit) = @ARGV;
    my $deadline = time + $limit;
    my $socket = IO::Socket::IP->new(PeerHost => $host, PeerPort => $port, Type => SOCK_STREAM, Timeout => $limit)
      or exit 1;
    my $request = "GET /health HTTP/1.0\r\nHost: $host:$port\r\nConnection: close\r\n\r\n";
    syswrite($socket, $request) == length($request) or exit 1;
    my ($select, $response) = (IO::Select->new($socket), "");
    while (1) {
      my $left = $deadline - time;
      exit 1 if $left <= 0;
      $select->can_read($left) or exit 1;
      my $count = sysread($socket, my $chunk, 65536);
      exit 1 unless defined $count;
      last if $count == 0;
      $response .= $chunk;
      exit 1 if length($response) > 262144;
    }
    my ($head, $body) = split /\r\n\r\n/, $response, 2;
    defined $body && $head =~ m{\AHTTP/1\.[01] 2[0-9][0-9] } or exit 1;
    my $health = eval { decode_json($body) };
    ref($health) eq "HASH" && defined($health->{app}) && $health->{app} eq "lavish-axi" or exit 1;
    exit 0;
  ' "$1" "$2" "$HEALTH_PROBE_TIMEOUT_SECONDS" >/dev/null 2>&1
}

# Back off after the preceding attempt finishes. Timing from before routing and
# CLI startup lets their variable latency compress neighboring poll starts.
poll_retry_wait() {  # <minimum-seconds>
  perl -MTime::HiRes=clock_gettime,sleep,CLOCK_MONOTONIC -e '
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + $ARGV[0];
    while (my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC)) {
      last if $remaining <= 0;
      sleep($remaining);
    }
  ' "$1"
}

# Whether this source's latest captured result already reports a held page,
# so a refusal that continues the same hold stays quiet. Timing: this is one
# perl pass over the source's results and runs outside any source lock;
# orphan_verdict reads no results, so its lock-held work stays constant in the
# number of result files.
held_page_reported() {  # <source-id>
  perl -e '
    my ($held, $top) = (0, -1);
    for my $path (@ARGV) {
      next if -l $path || !-f _;
      $path =~ /\.([0-9]+)\.result\z/ && $1 > $top or next;
      $top = 0 + $1;
      $held = 0;
      open my $in, "<", $path or next;
      my $first = <$in> // "";
      my $second = <$in> // "";
      close $in;
      $held = $first =~ /\Aerror:/ && $second =~ /\Acode:[ \t]*LISTENER_(?:ACTIVE|REPLACED)[ \t]*\n?\z/ ? 1 : 0;
    }
    exit($held ? 0 : 1);
  ' "$(fm_procevent_inbox_dir "${FM_STATE_OVERRIDE:-$FM_HOME/state}")/$1".*.result 2>/dev/null
}

# Exit 0 only when every other visible poll process on this page is a stray the
# `orphans` contract proves, and at least one exists. Prints one `held-by:` line
# per poll that is not proved, so a live claim's poll or any unproved or foreign
# poll is never displaced.
held_page_strays() {  # <artifact>
  local artifact=$1 id state own pid pgid lstart ppid plstart command strays=0 kept=0
  id=$(cmd_source_id "$artifact" 2>/dev/null) || return 1
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  own=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
  [ -n "$own" ] || return 1
  poller_prune "$(fm_procevent_registry_dir "$state")" "$id"
  while IFS=$'\t' read -r pid pgid lstart ppid plstart command; do
    [ "$pgid" != "$own" ] || continue
    if [ "$(cmd_source_id "$command" 2>/dev/null)" != "$id" ]; then
      # A poll naming this page beside extra options is still on this page.
      case " $command " in *" $artifact "*) ;; *) continue ;; esac
    fi
    orphan_verdict "$state" "$pid" "$pgid" "$lstart" "$ppid" "$plstart" "$command"
    if [ -z "$ORPHAN_REASON" ] && [ "$ORPHAN_ID" = "$id" ]; then
      strays=$((strays + 1))
    else
      kept=$((kept + 1))
      printf 'held-by: %s (%s)\n' "$pid" "${ORPHAN_REASON:-another source}"
    fi
  done < <(orphan_poll_processes)
  [ "$kept" -gt 0 ] || [ "$strays" -gt 0 ] || printf 'held-by: no visible poll process\n'
  [ "$kept" -eq 0 ] && [ "$strays" -gt 0 ]
}

cmd_poll() {
  local artifact=${1-} delay attempt=0 response cleanup_command rc filter_rc
  local pipeline_status reply_file='' takeover=() held_wait='' holders ledger
  local cap start_attempt=0 gone_strikes=0
  local reply_text='' reply_pending=0 store_attempt=0
  [ -n "$artifact" ] || usage
  if [ "$#" -eq 3 ] && [ "${2-}" = --agent-reply-file ]; then
    reply_file=$3
  elif [ "$#" -ne 1 ]; then
    usage
  fi
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  delay=$(poll_retry_delay) || exit 1
  cap=$(start_retry_cap) || exit 1
  response=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-poll.XXXXXX") || die "cannot stage the poll response"
  ledger=$(poller_record "$artifact") || ledger=
  printf -v cleanup_command 'rm -f -- %q' "$response"
  [ -z "$ledger" ] || printf -v cleanup_command '%s %q' "$cleanup_command" "$ledger"
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
        poll_retry_wait "$delay" \
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
      lavish-axi poll "$artifact" ${takeover[@]+"${takeover[@]}"} --agent-reply "$reply_text" | poll_response_filter "$response"
    else
      lavish-axi poll "$artifact" ${takeover[@]+"${takeover[@]}"} | poll_response_filter "$response"
    fi
    pipeline_status=("${PIPESTATUS[@]}")
    takeover=()
    rc=${pipeline_status[0]}
    filter_rc=${pipeline_status[1]}
    if [ "$reply_pending" -eq 1 ] && [ "$filter_rc" = 11 ]; then
      (umask 077; printf '%s\n' "$reply_text" > "$reply_file") \
        || die "cannot restage agent reply file: $reply_file"
    fi
    reply_pending=0
    case "$filter_rc" in
      0) break ;;
      10)
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          poll_retry_wait "$delay" \
            || die "cannot enforce the poll rate governor"
        else
          cat -- "$response"
          break
        fi
        ;;
      11)
        # A held page (header). Take it from a proved stray; otherwise report
        # the hold once and keep retrying it quietly with the waiting back-off.
        if holders=$(held_page_strays "$artifact"); then
          takeover=(--takeover)
          continue
        fi
        if ! held_page_reported "$(cmd_source_id "$artifact")"; then
          cat -- "$response"
          printf 'held-page: another poll holds %s and is not a proved leftover, so it is not displaced; this listener keeps its claim, retries with back-off, and reports this hold once\n' "$artifact"
          [ -z "$holders" ] || printf '%s\n' "$holders"
          break
        fi
        held_wait=${held_wait:-$delay}
        poll_retry_wait "$held_wait" \
          || die "cannot enforce the poll rate governor"
        held_wait=$((held_wait * 2))
        [ "$held_wait" -le "$POLL_RETRY_DELAY_MAX" ] || held_wait=$POLL_RETRY_DELAY_MAX
        ;;
      12)
        # The client's 500 ms health probe gave up on a server that may still be
        # alive. Quiet retries need a server that really answers; a refusal is
        # retried only until it has repeated START_GONE_LIMIT times in a row.
        if lavish_server_answers "$LAVISH_AXI_HOST" "$LAVISH_AXI_PORT"; then
          gone_strikes=0
        else
          gone_strikes=$((gone_strikes + 1))
        fi
        if [ "$start_attempt" -lt "$START_RETRY_LIMIT" ] && [ "$gone_strikes" -lt "$START_GONE_LIMIT" ]; then
          start_attempt=$((start_attempt + 1))
          poll_retry_wait "$(start_retry_wait "$start_attempt" "$delay" "$cap")" \
            || die "cannot enforce the poll rate governor"
        else
          cat -- "$response"
          break
        fi
        ;;
      *) die "cannot classify the poll response" ;;
    esac
  done
  # An outputless signal termination uses the runner's existing poll-again exit
  # rather than waiting for reconciliation. No local bytes does not prove the
  # server retained feedback; the header's destructive-poll loss limit still applies.
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

# The typed `code:` that follows a leading `error:` line, or nothing.
result_error_code() {  # <result-file>
  awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
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
  error_code=$(result_error_code "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  elif [ "$error_code" = LISTENER_ACTIVE ] || [ "$error_code" = LISTENER_REPLACED ]; then
    # Releases that refuse a second poller instead of answering `waiting`, or
    # that end this poll because another one took the page over.
    printf 'waiting\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. A LISTENER_REPLACED result is a held page, not an end: the listener
# waits for the other poll to finish and then listens again. Anything else -
# including an unreadable result - keeps the source armed.
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

# Decode the two published TOON collection forms once for read and choice rows.
# List items have scalar fields at four spaces; nested target metadata is deeper
# and must not overwrite the item text or selector. A nested array is not an
# item scalar either, but each `attachments` entry's `path` is kept with its
# item, in table or list form. Only column-zero headers
# frame a collection, never captain-supplied indented text.
result_items() {  # <result-file>
  perl -MJSON::PP -e '
    use strict; use warnings;
    open my $fh, "<:encoding(UTF-8)", $ARGV[0] or die "cannot read result: $!\n";
    my ($kind, $want, $form, @fields, @rows);
    my $header = "absent";
    while (my $line = <$fh>) {
      if ($header eq "absent") {
        next unless $line =~ /^(?:prompts|feedback)/;
        if ($line =~ /^(prompts|feedback)\[(\d+)\](?:\{([^}]+)\})?:\s*$/) {
          ($kind, $want, my $columns) = ($1, 0 + $2, $3);
          $form = defined($columns) ? "table" : "list";
          @fields = split /,/, $columns, -1 if defined $columns;
          $header = $form;
          $header = "unreadable" if grep { !/\A[A-Za-z][A-Za-z0-9_]*\z/ } @fields;
        } else {
          $header = "unreadable";
        }
        last if $header eq "unreadable";
        next;
      }
      last unless $line =~ /^\s/;
      chomp $line;
      push @rows, $line;
    }
    close $fh or die "cannot close result: $!\n";
    my (@parsed, $malformed);
    $malformed = 0;
    sub scalar_value {
      my ($value) = @_;
      return $value unless $value =~ /^"/;
      my $decoded = eval { JSON::PP->new->decode($value) };
      die "invalid quoted field" if $@ || !defined($decoded) || ref($decoded);
      return $decoded;
    }
    sub split_cells {
      my ($row) = @_;
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
      return (\@vals, $row);
    }
    sub unescape_cells {
      s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge for @_;
    }
    if ($header eq "table") {
      for my $row (@rows) {
        $row =~ s/^\s+//;
        my ($cells, $rest) = split_cells($row);
        my @vals = @$cells;
        $row = $rest;
        # Older captures emit unquoted freeform text containing commas.
        if (@vals > @fields) {
          my ($preserve) = grep { $fields[$_] eq "prompt" } 0 .. $#fields;
          ($preserve) = grep { $fields[$_] eq "text" } 0 .. $#fields unless defined $preserve;
          if (defined $preserve) {
            my @parts = splice @vals, $preserve, @vals - @fields + 1;
            splice @vals, $preserve, 0, join(",", @parts);
          }
        }
        if (@vals != @fields || length $row) { $malformed++; next }
        unescape_cells(@vals);
        my %item;
        @item{@fields} = @vals;
        push @parsed, \%item;
      }
    } elsif ($header eq "list") {
      my ($item, $invalid, $nested);
      my $close_nested = sub {
        return unless defined $nested;
        my $paths = $nested->{paths};
        $invalid = 1 if @$paths != $nested->{want} || grep { !defined($_) || $_ eq "" } @$paths;
        $item->{attachments} = $paths;
        undef $nested;
      };
      my $finish = sub {
        return unless defined $item;
        my @required = $kind eq "prompts" ? qw(uid prompt selector tag text) : qw(text);
        if ($invalid || grep { !exists $item->{$_} } @required) { $malformed++ }
        else { push @parsed, $item }
      };
      for my $line (@rows) {
        if ($line =~ /^  - (.*)$/) {
          $close_nested->();
          $finish->();
          $item = {}; $invalid = 0;
          $line = "    $1";
        }
        if (!defined $item) { $malformed++; next }
        $close_nested->() if $line =~ /^    \S/;
        if ($line =~ /^    ([A-Za-z][A-Za-z0-9_]*)\[(\d+)\](?:\{([^}]+)\})?:(?: (.*))?$/) {
          my ($key, $count, $columns, $inline) = ($1, 0 + $2, $3, $4);
          # A nested array is not an item scalar; only attachment paths are kept.
          next unless $key eq "attachments";
          if (exists $item->{$key} || defined $inline) { $invalid = 1; next }
          $nested = { want => $count, paths => [],
            fields => defined $columns ? [split /,/, $columns, -1] : undef };
        } elsif ($line =~ /^    ([A-Za-z][A-Za-z0-9_]*):(?: (.*))?$/) {
          my ($key, $value) = ($1, $2);
          # A nested object (notably target:) is not an item scalar.
          next unless defined $value;
          if (exists $item->{$key}) { $invalid = 1; next }
          my $decoded = eval { scalar_value($value) };
          if ($@) { $invalid = 1; next }
          $item->{$key} = $decoded;
        } elsif ($line !~ /^      /) {
          $invalid = 1;
        } elsif (defined $nested && defined $nested->{fields}) {
          if ($line !~ /^      (\S.*)$/) { $invalid = 1; next }
          my ($cells, $rest) = split_cells($1);
          my @vals = @$cells;
          if (@vals != @{$nested->{fields}} || length $rest) { $invalid = 1; next }
          unescape_cells(@vals);
          my %attachment;
          @attachment{@{$nested->{fields}}} = @vals;
          push @{$nested->{paths}}, $attachment{path};
        } elsif (defined $nested) {
          if ($line =~ /^      - (.*)$/) {
            push @{$nested->{paths}}, undef;
            $line = "        $1";
          }
          next unless $line =~ /^        path: (.*)$/;
          if (!@{$nested->{paths}} || defined $nested->{paths}[-1]) { $invalid = 1; next }
          my $path = eval { scalar_value($1) };
          if ($@) { $invalid = 1; next }
          $nested->{paths}[-1] = $path;
        }
      }
      $close_nested->();
      $finish->();
    }
    print encode_json({ header => $header, want => $want, kind => $kind,
      parsed => \@parsed, malformed => $malformed });
  ' "$1"
}

# Whether a completed result carries any queued content block at all. The
# published response frames content as a top-level table or list header for
# `prompts[N]` or `feedback[N]` whose rows are INDENTED, so this anchors on column
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
    /^(prompts|feedback)\[[0-9]+\](\{[^}]*\})?:[[:space:]]*$/ {
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
# a table (`prompts[N]{field,...}:` with indented CSV rows) or a list
# (`prompts[N]:` with indented objects). The shared decoder reads declared table
# field order or list scalar keys and takes only rows whose `tag` is `choice`. A freeform `message` row is captain prose and is deliberately never a
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
  result_items "$file" | perl -MJSON::PP -e '
    use strict; use warnings;
    my ($selection, $lifecycle) = @ARGV;
    binmode STDOUT, ":encoding(UTF-8)";
    my $capture = decode_json(do { local $/; <STDIN> });
    exit 1 if $capture->{header} eq "unreadable"
      || ($capture->{header} eq "absent" && $lifecycle =~ /^(?:feedback|unknown)$/);
    exit 0 unless defined($capture->{kind}) && $capture->{kind} eq "prompts";
    my %seen;
    my @choices;
    for my $item (@{$capture->{parsed}}) {
      my %f = %$item;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      my $data = eval { JSON::PP->new->decode($ctx) };
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
  ' "$selection" "$(cmd_classify "$file")"
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
# out of that field. A pure annotation has no prompt. Each image the captain
# attached prints as an `attachment_path:` line with its message or annotation.
cmd_read() {
  local file=${1-} lifecycle session_ended
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  lifecycle=$(cmd_classify "$file")
  session_ended=$(session_field "$file" session_ended)
  result_items "$file" | perl -MJSON::PP -e '
    use strict; use warnings;
    my ($lifecycle, $session_ended) = @ARGV;
    binmode STDOUT, ":encoding(UTF-8)";
    my $capture = decode_json(do { local $/; <STDIN> });
    my $unreadable = $capture->{header} eq "unreadable"
      || ($capture->{header} eq "absent" && $lifecycle =~ /^(?:feedback|unknown)$/);
    my $want = $unreadable ? "unreadable" : (defined($capture->{want}) ? $capture->{want} : 0);
    my @parsed = @{$capture->{parsed}};
    my $malformed = $capture->{malformed};
    my $presented = scalar @parsed;
    my $complete = (!$unreadable && $presented == $want && !$malformed) ? "yes" : "no";
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
    sub emit_attachments {
      my ($item) = @_;
      for my $path (@{$item->{attachments} || []}) {
        (my $shown = $path) =~ s/[\x00-\x1f\x7f]/ /g;
        print "attachment_path: $shown\n";
      }
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
        emit_attachments($messages[$i]);
      }
      print "END $message_label\n";
    } else {
      print "SESSION-ENDING MESSAGE: (none)\n";
    }
    print "\n";
    print "parse_status: ", ($unreadable ? "unreadable" : "readable"), "\n";
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
        emit_attachments($f);
      }
      print "END ANNOTATIONS\n";
    } else {
      print $unreadable ? "ANNOTATIONS: (unreadable)\n" : "ANNOTATIONS: (none)\n";
    }
    print "END LAVISH RESULT ($presented of $want)\n";
    exit 1 if $unreadable;
  ' "$lifecycle" "$session_ended"
}

# --- orphans: leftover poll processes no listener owns -----------------------
# The header owns the eligibility contract. Start times are `ps` lstart under the
# C locale with whitespace collapsed, the one form every writer and reader uses.

# Record this adapter process in this home's registry for the artifact's source
# and print the record path. A record is "pid\nlstart\npgid\n", published by
# rename so a scan never reads it half written.
poller_record() {  # <artifact>
  local id reg lstart pgid tmp rec
  id=$(cmd_source_id "$1" 2>/dev/null) || return 1
  reg=$(fm_procevent_registry_dir "${FM_STATE_OVERRIDE:-$FM_HOME/state}")
  [ -d "$reg" ] || return 1
  lstart=$(LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null | awk '{ $1 = $1; print }')
  pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
  [ -n "$lstart" ] && [ -n "$pgid" ] || return 1
  rec="$reg/$id.$$.poller"
  tmp=$(umask 077; mktemp "$reg/.poller.XXXXXX") || return 1
  if printf '%s\n%s\n%s\n' "$$" "$lstart" "$pgid" > "$tmp" && mv -f -- "$tmp" "$rec"; then
    printf '%s\n' "$rec"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Drop poller records, for one source or all, whose process is gone or started
# at another time. The records are listed before the process snapshot is taken,
# so a record's live writer is always in that snapshot.
poller_prune() {  # <registry-dir> [<source-id>]
  local records=()
  if [ -n "${2-}" ]; then
    records=("$1/$2".*.poller)
  else
    records=("$1"/*.poller)
  fi
  LC_ALL=C perl -e '
    use strict; use warnings;
    my %start;
    open my $ps, "-|", "ps", "-axo", "pid=,lstart=" or exit 1;
    while (my $line = <$ps>) {
      my ($pid, $lstart) = $line =~ /\A\s*(\d+)\s+(.*?)\s*\z/ or next;
      $lstart =~ s/\s+/ /g;
      $start{$pid} = $lstart;
    }
    close $ps or exit 1;
    for my $rec (@ARGV) {
      next if -l $rec || !-f _;
      open my $in, "<", $rec or next;
      my $pid = <$in> // "";
      my $lstart = <$in> // "";
      close $in;
      chomp($pid, $lstart);
      unlink $rec unless $pid =~ /\A\d+\z/ && defined $start{$pid} && $start{$pid} eq $lstart;
    }
  ' "${records[@]}" 2>/dev/null || true
}

# Whether this home's poller record for <source-id> proves <pid> started at
# <lstart> is that source's poll adapter.
poller_recorded() {  # <registry-dir> <source-id> <pid> <lstart>
  local rec="$1/$2.$3.poller" pid lstart
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 1
  { IFS= read -r pid && IFS= read -r lstart; } < "$rec" || return 1
  [ "$pid" = "$3" ] && [ -n "$lstart" ] && [ "$lstart" = "$4" ]
}

# Prints "pid<TAB>pgid<TAB>lstart<TAB>ppid<TAB>parent-lstart<TAB>artifact" for
# every process whose command is a Lavish poll; parent-lstart is "-" when the
# parent is not visible.
orphan_poll_processes() {
  LC_ALL=C ps -axo pid=,ppid=,pgid=,lstart=,command= 2>/dev/null | perl -e '
    use strict; use warnings;
    my (%start, @polls);
    while (my $line = <STDIN>) {
      chomp $line;
      $line =~ /\A\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+\d+:\d+:\d+\s+\d+)\s+(.*)\z/ or next;
      my ($pid, $ppid, $pgid, $lstart, $command) = ($1, $2, $3, $4, $5);
      $lstart =~ s/\s+/ /g;
      $start{$pid} = $lstart;
      $command =~ m{(?:\A|[ /])(?:lavish-axi|fm-procevent-lavish\.sh) poll (.+?)(?: --takeover)?(?: --agent-reply(?:-file)? .+)?\z} or next;
      my $artifact = $1;
      next if $artifact =~ /\t/;
      push @polls, [$pid, $pgid, $lstart, $ppid, $artifact];
    }
    for my $poll (@polls) {
      my ($pid, $pgid, $lstart, $ppid, $artifact) = @$poll;
      print join("\t", $pid, $pgid, $lstart, $ppid, $start{$ppid} // "-", $artifact), "\n";
    }
  '
}

# Why one Lavish poll process is not a provable orphan, per the header's
# contract, in ORPHAN_REASON; empty when every fact is proved. ORPHAN_ID names
# its source.
orphan_verdict() {  # <state-dir> <pid> <pgid> <lstart> <ppid> <parent-lstart> <artifact>
  local pid=$2 pgid=$3 reg
  ORPHAN_REASON='' ORPHAN_ID=''
  reg=$(fm_procevent_registry_dir "$1")
  if ! ORPHAN_ID=$(cmd_source_id "$7" 2>/dev/null); then
    ORPHAN_REASON='artifact cannot be resolved'
    return 0
  fi
  if ! poller_recorded "$reg" "$ORPHAN_ID" "$pid" "$4" \
    && ! poller_recorded "$reg" "$ORPHAN_ID" "$5" "$6"; then
    ORPHAN_REASON='no poller record'
    return 0
  fi
  if ! fm_procevent_source_lock_try_acquire "$ORPHAN_ID" 2>/dev/null; then
    ORPHAN_REASON='source is busy'
    return 0
  fi
  if fm_procevent_claim_load_locked "$ORPHAN_ID" 2>/dev/null; then
    if [ "$FM_PROCEVENT_CLAIM_PID" = "$pgid" ] || [ "$FM_PROCEVENT_CLAIM_PID" = "$pid" ]; then
      ORPHAN_REASON='owned by a claim'
    fi
  elif [ -e "$(fm_procevent_claim_path "$ORPHAN_ID")" ]; then
    ORPHAN_REASON='claim cannot be read'
  fi
  fm_procevent_source_lock_release "$ORPHAN_ID" 2>/dev/null || true
}

cmd_orphans() {
  local kill_mode=0 state pid pgid lstart ppid plstart artifact identity reason i
  local found=0 killed=0 kept=0
  local -a pids=() ids=() artifacts=() identities=() reasons=()
  case "${1-}" in
    '') ;;
    --kill) kill_mode=1; shift ;;
    *) usage ;;
  esac
  [ "$#" -eq 0 ] || usage
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  poller_prune "$(fm_procevent_registry_dir "$state")"
  # Every verdict is decided before any signal, because a signalled adapter
  # removes the record that proves its native child.
  while IFS=$'\t' read -r pid pgid lstart ppid plstart artifact; do
    [ -n "$pid" ] && [ "$pid" != "$$" ] || continue
    identity=$(fm_pid_identity "$pid" 2>/dev/null) || continue
    orphan_verdict "$state" "$pid" "$pgid" "$lstart" "$ppid" "$plstart" "$artifact"
    pids+=("$pid") ids+=("$ORPHAN_ID") artifacts+=("$artifact")
    identities+=("$identity") reasons+=("$ORPHAN_REASON")
  done < <(orphan_poll_processes)
  for i in "${!pids[@]}"; do
    pid=${pids[$i]} artifact=${artifacts[$i]} reason=${reasons[$i]}
    if [ -z "$reason" ]; then
      found=$((found + 1))
      if [ "$kill_mode" -eq 0 ]; then
        printf 'orphan: %s %s %s\n' "$pid" "${ids[$i]}" "$artifact"
      elif [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${identities[$i]}" ] && kill -TERM "$pid" 2>/dev/null; then
        killed=$((killed + 1))
        printf 'killed: %s %s %s\n' "$pid" "${ids[$i]}" "$artifact"
      else
        found=$((found - 1))
        reason='process changed before the signal'
      fi
    fi
    if [ -n "$reason" ]; then
      kept=$((kept + 1))
      printf 'kept: %s (%s) %s\n' "$pid" "$reason" "$artifact"
    fi
  done
  printf 'orphans: found=%s killed=%s kept=%s\n' "$found" "$killed" "$kept"
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
  orphans)   shift; cmd_orphans "$@" ;;
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
        disconnected) ;;
        waiting) waiting_result=$1 ;;
        *) exit 1 ;;
      esac
    fi
    delay=$(poll_retry_delay) || exit 1
    [ -z "${waiting_result-}" ] || delay=$(waiting_retry_delay "$waiting_result" "$delay")
    sleep "$delay"
    ;;
  silent)    shift; cmd_silent "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  reconciles) shift; cmd_reconciles "$@" ;;
  read)      shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
