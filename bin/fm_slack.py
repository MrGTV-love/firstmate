#!/usr/bin/env python3
"""Slack Web API transport only. Shell entry points own environment resolution."""
import json
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


class Slack:
    base = 'https://slack.com/api/'

    def __init__(self, token):
        self.token = token
        # measured: 10 seconds, 2026-10-18, operator host, conservative socket ceiling.
        # The standing check additionally bounds the whole process.
        self.deadline = time.monotonic() + 20
        self.scopes = set()

    def call(self, method, **fields):
        if not self.token:
            raise SlackError('missing_token')
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise SlackError('request_budget_exhausted')
        encoded = {key: json.dumps(value) if isinstance(value, (dict, list, bool)) else value
                   for key, value in fields.items()}
        request = urllib.request.Request(self.base + method,
            data=urllib.parse.urlencode(encoded).encode(),
            headers={'Authorization': 'Bearer ' + self.token,
                     'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'})
        try:
            with urllib.request.urlopen(request, timeout=min(10, remaining)) as response:
                header = response.headers.get('x-oauth-scopes', '')
                if header:
                    self.scopes = {s for s in header.replace(' ', '').split(',') if s}
                raw = response.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    raise SlackError('response_too_large')
                # Scrub before any successful body can reach output or state.
                data = json.loads(raw.decode(errors='replace').replace(self.token, '[REDACTED]'))
        except urllib.error.HTTPError as error:
            if error.code == 429:
                raise SlackError('rate_limited') from None
            raise SlackError('http_' + str(error.code)) from None
        except (OSError, ValueError, urllib.error.URLError):
            raise SlackError('unreachable') from None
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

