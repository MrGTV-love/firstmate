"""Test-only redirect: every Slack API URL goes to the local fake server. Any other host is refused."""
import os
import urllib.parse
import urllib.request

_base = os.environ['FAKE_SLACK_BASE']
_orig = urllib.request.urlopen


def _redirected(request, *args, **kwargs):
    url = request.full_url if hasattr(request, 'full_url') else request
    if not url.startswith('https://slack.com/api/'):
        raise OSError('fake-slack shim refuses ' + url)
    new = _base + url[len('https://slack.com/api/'):]
    request.full_url = new
    return _orig(request, *args, **kwargs)


urllib.request.urlopen = _redirected
