#!/usr/bin/env python3
"""Slack Web API transport only. Shell entry points own environment resolution."""
import json
import os
import urllib.error
import urllib.parse
import urllib.request


class SlackError(Exception):
    pass


class SecretCollision(SlackError):
    """A plane value that no replacement of request text can remove: it holds no request-text character."""


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


def outbound_texts(fields):
    """Every string the receiver of one call is handed: a string field as it is, a dict or list field as the JSON the transport sends (in both
    encodings of non-ASCII characters), anything else as its text. The Authorization header is not a field and is never in this list."""
    texts = []
    for value in fields.values():
        if isinstance(value, str):
            texts.append(value)
        elif isinstance(value, (dict, list)):
            texts += [json.dumps(value), json.dumps(value, ensure_ascii=False)]
        elif value is not None and not isinstance(value, (bool, int, float)):
            texts.append(str(value))
    return texts


def outbound_hit(fields):
    """Whether any string of one outbound call holds a plane value."""
    return any(value_hits(text) for text in outbound_texts(fields))


def refuse_outbound(fields):
    """The one check every outbound call passes before any byte of it exists (a request, an attempt record, a log line): a call whose fields hold a
    plane value is not made."""
    if outbound_hit(fields):
        raise SecretCollision('secret_collides_with_marker')


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
    scrub_with = '[REDACTED]'

    def __init__(self, token):
        self.token = token
        self.scopes = set()

    def call(self, method, **fields):
        if not self.token:
            raise SlackError('missing_token')
        refuse_outbound(fields)
        encoded = {key: json.dumps(value) if isinstance(value, (dict, list, bool)) else value
                   for key, value in fields.items()}
        request = urllib.request.Request(self.base + method,
            data=urllib.parse.urlencode(encoded).encode(),
            headers={'Authorization': 'Bearer ' + self.token,
                     'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'})
        try:
            # Conservative socket ceiling, first set 2026-10-18 on the operator host.
            # A hung check can starve supervision: fm-watch.sh owns its progress
            # and absolute bounds. Time between requests is not a socket failure.
            # measured: value=10 date=2026-10-31 host=Mac-Studio.local margin=1.1 (at 5-minute load 185-195 a whole hand-run poll took 9 s and a mirror 6 s, so no single request exceeded 9 s)
            with urllib.request.urlopen(request, timeout=10) as response:
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

