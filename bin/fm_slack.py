#!/usr/bin/env python3
"""Slack Web API transport only. Shell entry points own environment resolution."""
import datetime
import email.utils
import http.client
import json
import os
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class SlackError(Exception):
    pass


class SecretCollision(SlackError):
    """A plane value that no replacement of request text can remove: it holds no request-text character."""


# How long a call cut off at its deadline waits for its reader to end once the reader's socket is closed (Slack._bounded).
CUTOFF_JOIN = 1.0
# The per-call state of one call, for the thread that makes it (Main 3345 (a)): the second person's pass makes two calls at once on one transport, a post
# and a thread read, so the time left of a call and the scrub text of a read belong to that call, never to the transport. Unset, the transport's own apply.
CALL = threading.local()
# A name lookup's answer, kept for the rest of a short run (one check process): calls made at once need no lookup of their own, so the rule of at most one
# live lookup per process (F9 of the review of c5868b6f) never refuses a call because another call is looking the same name up.
RESOLVE_TTL = 60.0
_RESOLVED = {}


class _Fence:
    """Everything one bounded exchange opens (Main 1621 (9), 1623, 1671 (2)): the reader owns the whole exchange, name lookup and connection set-up included.
    The name lookup runs in a lookup thread the reader waits on only for the time left; each socket is registered (a duplicate of its descriptor, which reaches
    the same connection after a TLS wrap) BEFORE it connects; connect and the TLS handshake use the time left as their timeout. Closing the fence shuts down and
    closes every registered descriptor and refuses every later connection, so nothing is sent after it closes: a lookup that ends late finds it closed before any
    socket exists. `connected` says whether any connection was made (so whether anything could have been sent)."""

    def __init__(self, time_left):
        self.time_left = time_left
        self.lock = threading.Lock()
        self.duplicates = []
        self.closed = False
        self.connected = False
        self.lookup_pending = False

    def left(self):
        return max(0.0, self.time_left())

    def check(self):
        if self.closed or self.left() <= 0:
            raise DeadlineSpent(sent=self.connected)

    def create(self, address, timeout=None, source_address=None, *args, **kwargs):
        """socket.create_connection, fenced (http.client calls it for the plain and the TLS connection, and for a proxy)."""
        host, port = address
        self.check()
        found = []
        with _LOOKUPS:
            known = _RESOLVED.get((host, port))
            if known is not None and known[0] > time.monotonic():
                found.append(known[1])
            else:
                # At most one live name lookup per process (F9 of the review of c5868b6f): a lookup still running from an earlier, cut-off call refuses this
                # one, which then sends nothing; it cannot be cancelled, so it is never multiplied.
                if any(t.is_alive() for t in _LOOKUP_THREADS):
                    self.lookup_pending = True
                    raise DeadlineSpent(sent=False)
                lookup = threading.Thread(target=lambda: found.append(self.resolve(host, port)), name='fm-slack-lookup', daemon=True)
                _LOOKUP_THREADS[:] = [lookup]
                lookup.start()
        if not found:
            lookup.join(self.left())
        if not found:
            self.lookup_pending = True
            raise DeadlineSpent(sent=False)
        if isinstance(found[0], BaseException):
            raise found[0]
        with _LOOKUPS:
            _RESOLVED[(host, port)] = (time.monotonic() + RESOLVE_TTL, found[0])
        error = None
        for family, kind, proto, _, where in found[0]:
            sock = socket.socket(family, kind, proto)
            with self.lock:
                if self.closed:
                    sock.close()
                    raise DeadlineSpent(sent=self.connected)
                self.duplicates.append(sock.dup())
            try:
                self.check()
                sock.settimeout(min(self.left(), timeout) if isinstance(timeout, (int, float)) else self.left())
                if source_address:
                    sock.bind(source_address)
                sock.connect(where)
                with self.lock:
                    if self.closed:
                        raise DeadlineSpent(sent=True)
                    self.connected = True
                return sock
            except OSError as failure:
                error = failure
                sock.close()
        raise error or OSError('no_address')

    @staticmethod
    def resolve(host, port):
        try:
            return socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)
        except OSError as error:
            return error

    def close(self):
        """At the deadline: shut down and close every registered descriptor; refuse every later connection."""
        with self.lock:
            self.closed = True
            duplicates, self.duplicates = list(self.duplicates), []
        for dup in duplicates:
            for end in (lambda: dup.shutdown(socket.SHUT_RDWR), dup.close):
                try:
                    end()
                except OSError:
                    pass

    def release(self):
        """After a completed exchange: close the registered duplicates only (the exchange closed its own sockets)."""
        with self.lock:
            duplicates, self.duplicates = list(self.duplicates), []
        for dup in duplicates:
            try:
                dup.close()
            except OSError:
                pass


_LOOKUPS = threading.Lock()
_LOOKUP_THREADS = []


def _fenced(base, fence):
    class Fenced(base):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self._create_connection = fence.create

    return Fenced


class _FencedHTTP(urllib.request.HTTPHandler):
    def __init__(self, fence):
        super().__init__()
        self.fence = fence

    def http_open(self, req):
        return self.do_open(_fenced(http.client.HTTPConnection, self.fence), req)


class _FencedHTTPS(urllib.request.HTTPSHandler):
    def __init__(self, fence):
        super().__init__()
        self.fence = fence

    def https_open(self, req):
        return self.do_open(_fenced(http.client.HTTPSConnection, self.fence), req, context=self._context)


class DeadlineSpent(Exception):
    """A call of a caller with a total deadline (Slack.time_left) that could not be begun, or could not end, before that deadline. It is not a Slack failure.
    sent is False when no connection was ever made, so nothing of the call reached Slack (surely absent); otherwise whether it reached Slack is unknown."""

    def __init__(self, sent=True):
        super().__init__()
        self.sent = sent


def plane_secrets():
    """The plane's own secret values, longest first: the bot token as configured and as the plane sends it (stripped),
    and the signing secret exactly as configured; text that holds none of them exactly is never changed."""
    token = os.environ.get('SLACK_BOT_TOKEN', '')
    values = {token, token.strip(), os.environ.get('SLACK_SIGNING_SECRET', '')}
    return sorted((value for value in values if value.strip()), key=len, reverse=True)


def value_hits(text):
    """The sink check: the (start, end) spans, merged, of every plane secret value in the COMPLETE text of one sink (a whole file after an append, a
    whole stream, one printed line, one outbound field). Pure: it reads and changes nothing, and it is the only judge of whether a sink holds a value."""
    spans = []
    for value in plane_secrets():
        at = text.find(value)
        while at >= 0:
            spans.append((at, at + len(value)))
            at = text.find(value, at + 1)
    merged = []
    for start, end in sorted(spans):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def wire_body(fields):
    """The request body exactly as the transport sends it: the fields form-encoded, a dict, a list or a boolean as JSON."""
    encoded = {key: json.dumps(value) if isinstance(value, (dict, list, bool)) else value for key, value in fields.items()}
    return urllib.parse.urlencode(encoded)


def outbound_texts(fields, wire=False):
    """Every string the receiver of one call is handed: a string field as it is, a dict or list field as the JSON the transport sends (in both
    encodings of non-ASCII characters), anything else as its text; with wire, also the request body as it goes on the wire (its field names and
    separators are fixed text too). The Authorization header is not a field and is never in this list."""
    texts = []
    for value in fields.values():
        if isinstance(value, str):
            texts.append(value)
        elif isinstance(value, (dict, list)):
            texts += [json.dumps(value), json.dumps(value, ensure_ascii=False)]
        elif value is not None and not isinstance(value, (bool, int, float)):
            texts.append(str(value))
    if wire:
        texts.append(wire_body(fields))
    return texts


def outbound_hit(fields, wire=False):
    """Whether any string of one outbound call holds a plane value."""
    return any(value_hits(text) for text in outbound_texts(fields, wire))


def refuse_outbound(fields, wire=False):
    """The one check every outbound call passes before any byte of it exists (a request, an attempt record, a log line): a call whose fields hold a
    plane value is not made."""
    if outbound_hit(fields, wire):
        raise SecretCollision('secret_collides_with_marker')


# Slack's chat.postMessage documents that internal_error and fatal_error can follow a partly successful operation; service_unavailable says no more.
OUTCOME_UNKNOWN_ERRORS = frozenset({'internal_error', 'fatal_error', 'service_unavailable'})
SAFE_ERRORS = {
    'invalid_auth', 'token_revoked', 'not_authed', 'account_inactive',
    'missing_scope', 'not_in_channel', 'channel_not_found', 'user_not_found',
    'invalid_arguments', 'ratelimited',
}


# A reader that wants to know that the transport removed its token from a response sets scrub_with to SCRUB_MARK followed by
# its own marker text; the character is a Unicode noncharacter, which Slack text does not carry.
SCRUB_MARK = '\ufdd0'


class Slack:
    base = 'https://slack.com/api/'
    on_reply = None
    # Called with Slack's clock (seconds since the epoch) each time a reply carries a Date the transport can read.
    on_date = None
    scrub_with = '[REDACTED]'

    def __init__(self, token):
        self.token = token
        self.scopes = set()
        # Slack's own clock as the last reply reported it in its Date header (seconds since the epoch), or None when that reply carried no Date that can be read: each
        # reply alone, never a value kept from an earlier one (finding 2 of the review of d0b0c216). The only clock a Slack timestamp may be ordered against.
        self.server_time = None

    # A caller with a total deadline sets time_left to a function that gives the seconds left (the second person's pass, SECOND_BUDGET); None is no total bound.
    time_left = None
    # The last call cut off at its deadline: {'ended': whether its reader ended after its socket was closed, 'closed_at': when (monotonic), 'lookup_pending': whether a
    # name lookup was still running, 'sent': whether a connection was made, 'begun': False for a call refused with no time left} (_bounded).
    last_cutoff = None

    def call(self, method, **fields):
        if not self.token:
            raise SlackError('missing_token')
        refuse_outbound(fields, wire=True)
        self.server_time = None
        request = urllib.request.Request(self.base + method,
            data=wire_body(fields).encode(),
            headers={'Authorization': 'Bearer ' + self.token,
                     'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'})
        # Conservative socket ceiling, first set 2026-10-18 on the operator host.
        # A hung check can starve supervision: fm-watch.sh owns its progress
        # and absolute bounds. Time between requests is not a socket failure.
        # measured: value=10 date=2026-10-31 host=Mac-Studio.local margin=1.1 (at 5-minute load 185-195 a whole hand-run poll took 9 s and a mirror 6 s, so no single request exceeded 9 s)
        time_left = getattr(CALL, 'time_left', None) or self.time_left
        scrub_with = getattr(CALL, 'scrub_with', None)
        if time_left is None:
            date, header, data, error = self._exchange(request, 10) if scrub_with is None else self._exchange(request, 10, scrub_with=scrub_with)
        else:
            date, header, data, error = self._bounded(request, time_left, scrub_with)
        if date is not None:
            self._note_date(date)
        if header:
            self.scopes = {s for s in header.replace(' ', '').split(',') if s}
        if error is not None:
            raise error
        if self.on_reply:
            self.on_reply()
        if not isinstance(data, dict) or not data.get('ok'):
            code = data.get('error', '') if isinstance(data, dict) else ''
            # Never relay arbitrary API text, including an echoed Authorization header. The errors after which Slack says an operation may have partly
            # succeeded get one fixed name of their own (round 8, R9); every other unnamed error stays api_error.
            raise SlackError(code if code in SAFE_ERRORS else 'slack_outcome_unknown' if code in OUTCOME_UNKNOWN_ERRORS else 'api_error')
        return data

    def _bounded(self, request, time_left=None, scrub_with=None):
        """One exchange under the caller's total deadline (Main 1593, 1621 (9) and 1623 (1)): the socket timeout bounds each wait, so a reply that trickles in byte by
        byte never hits it; the exchange therefore runs in a reader thread, with the time left as its socket timeout, that this call waits for only as long as
        time_left() allows. At the deadline the caller ends the exchange itself: it shuts down and closes the exchange's socket, which unblocks the reader with no
        signal, and joins the reader for at most CUTOFF_JOIN seconds; whether it ended is kept in last_cutoff. A reader that had not yet connected (name lookup)
        cannot send after that: its connection is refused at once (_Fence). A call with no time left is not begun. The reader changes nothing of the transport.
        Returns the exchange's outcome, or raises DeadlineSpent. time_left and scrub_with are this call's own (CALL), else the transport's."""
        time_left = time_left or self.time_left
        left = time_left()
        if left <= 0:
            # Not begun: nothing was looked up or sent. Recorded as every cut-off is (F9 of the review of c5868b6f).
            self.last_cutoff = {'ended': True, 'closed_at': time.monotonic(), 'lookup_pending': False, 'sent': False, 'begun': False}
            raise DeadlineSpent(sent=False)
        fence = _Fence(time_left)
        opener = urllib.request.build_opener(_FencedHTTP(fence), _FencedHTTPS(fence))
        outcome = []
        if scrub_with is None:
            exchange = lambda: outcome.append(self._exchange(request, min(10, left), opener))
        else:
            exchange = lambda: outcome.append(self._exchange(request, min(10, left), opener, scrub_with=scrub_with))
        reader = threading.Thread(target=exchange, name='fm-slack-bounded', daemon=True)
        reader.start()
        reader.join(max(0.0, time_left()))
        if outcome:
            fence.release()
            if isinstance(outcome[0][3], DeadlineSpent):
                # Cut off inside the reader (its lookup ran out of time, or another lookup was still alive): recorded as every cut-off is (F9).
                self.last_cutoff = {'ended': True, 'closed_at': time.monotonic(), 'lookup_pending': fence.lookup_pending, 'sent': fence.connected, 'begun': True}
            return outcome[0]
        fence.close()
        closed_at = time.monotonic()
        reader.join(CUTOFF_JOIN)
        self.last_cutoff = {'ended': not reader.is_alive(), 'closed_at': closed_at, 'lookup_pending': fence.lookup_pending, 'sent': fence.connected, 'begun': True}
        raise DeadlineSpent(sent=fence.connected)

    def _exchange(self, request, timeout, opener=None, scrub_with=None):
        """One HTTP exchange: (the reply's Date header or None, its x-oauth-scopes header, the parsed body or None, the error to raise or None). It reads and writes
        no state of the transport, so that _bounded() can run it in a thread it may abandon; call() applies what it returns."""
        date, header = None, ''
        try:
            with (opener.open if opener else urllib.request.urlopen)(request, timeout=timeout) as response:
                date = response.headers.get('Date', '')
                header = response.headers.get('x-oauth-scopes', '')
                raw = response.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    return date, header, None, SlackError('response_too_large')
                # Scrub before any successful body can reach output or state.
                return date, header, json.loads(raw.decode(errors='replace').replace(self.token, scrub_with or self.scrub_with)), None
        except urllib.error.HTTPError as error:
            if error.code == 429:
                return date, header, None, SlackError('rate_limited')
            return date, header, None, SlackError('http_' + str(error.code))
        except (OSError, ValueError, urllib.error.URLError):
            return date, header, None, SlackError('unreachable')
        except Exception as error:
            # Any other error is raised by call() as it is, after the Date and scopes this reply gave, exactly as before this split.
            return date, header, None, error

    def _note_date(self, value):
        """Record Slack's clock from this reply's Date header; a header that is missing or cannot be read gives no clock for this reply (server_time stays None).
        A date with no zone (`-0000`) is read as UTC, as an HTTP date always is, and never as this host's local time."""
        try:
            moment = email.utils.parsedate_to_datetime(value)
        except (TypeError, ValueError, IndexError):
            return
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=datetime.timezone.utc)
        self.server_time = moment.timestamp()
        if self.on_date:
            self.on_date(self.server_time)

    def pages(self, method, field, **fields):
        cursor = ''
        seen = set()
        while True:
            args = dict(fields, limit=100)
            if cursor:
                args['cursor'] = cursor
            data = self.call(method, **args)
            yield from data.get(field, [])
            cursor = data.get('response_metadata', {}).get('next_cursor', '')
            if not cursor:
                break
            if cursor in seen:
                raise SlackError('repeated_page_cursor')
            seen.add(cursor)

