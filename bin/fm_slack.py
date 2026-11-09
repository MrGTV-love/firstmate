#!/usr/bin/env python3
"""Slack Web API transport only. Shell entry points own environment resolution."""
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class SlackError(Exception):
    pass


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
    on_wait = None
    scrub_with = '[REDACTED]'
    # No fixed deadline ends a request: a reply that is slow is still a reply. A request that has waited this many seconds raises
    # an alarm (on_wait, or one line on standard error) and again after each further stretch of this length, and keeps waiting.
    # A request fails as unreachable only when the connection itself fails. fm-watch.sh owns the standing check's progress and
    # absolute bounds; the alarm line is standard error, which it counts as progress.
    # measured: value=10 date=2026-10-31 host=Mac-Studio.local margin=1.1 (at 5-minute load 185-195 a whole hand-run poll took 9 s and a mirror 6 s, so no single request exceeded 9 s)
    alarm_every = 10

    def __init__(self, token):
        self.token = token
        self.scopes = set()

    @staticmethod
    def _waiting_line(method, seconds):
        return ('slack: request %s still waiting after %ds; it keeps waiting\n' % (method, seconds)).encode()

    def _raise_alarm(self, method, seconds):
        if self.on_wait:
            self.on_wait(method, seconds)
        else:
            os.write(2, self._waiting_line(method, int(seconds)))

    def _watch_the_wait(self, method):
        """Start the alarm of one request; the returned event stops it."""
        done = threading.Event()
        started = time.monotonic()

        def run():
            while not done.wait(self.alarm_every):
                self._raise_alarm(method, time.monotonic() - started)
        threading.Thread(target=run, daemon=True).start()
        return done

    def call(self, method, **fields):
        if not self.token:
            raise SlackError('missing_token')
        encoded = {key: json.dumps(value) if isinstance(value, (dict, list, bool)) else value
                   for key, value in fields.items()}
        request = urllib.request.Request(self.base + method,
            data=urllib.parse.urlencode(encoded).encode(),
            headers={'Authorization': 'Bearer ' + self.token,
                     'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'})
        waiting = self._watch_the_wait(method)
        try:
            with urllib.request.urlopen(request) as response:
                header = response.headers.get('x-oauth-scopes', '')
                if header:
                    self.scopes = {s for s in header.replace(' ', '').split(',') if s}
                raw = response.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    raise SlackError('response_too_large')
                # Scrub before any successful body can reach output or state.
                data = json.loads(raw.decode(errors='replace').replace(self.token, self.scrub_with))
        except urllib.error.HTTPError as error:
            if error.code == 429:
                raise SlackError('rate_limited') from None
            raise SlackError('http_' + str(error.code)) from None
        except (OSError, ValueError, urllib.error.URLError):
            raise SlackError('unreachable') from None
        finally:
            waiting.set()
        if self.on_reply:
            self.on_reply()
        if not isinstance(data, dict) or not data.get('ok'):
            code = data.get('error', '') if isinstance(data, dict) else ''
            # Never relay arbitrary API text, including an echoed Authorization header.
            raise SlackError(code if code in SAFE_ERRORS else 'api_error')
        return data

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

