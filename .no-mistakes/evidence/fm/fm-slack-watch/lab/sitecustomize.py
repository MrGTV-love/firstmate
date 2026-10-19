"""Redirect the real Slack client to the loopback fake. Only slack.com/api URLs move.

Loaded through PYTHONPATH; the product code is untouched. Fails closed: when
LAB_SLACK_PORT is unset the request is refused instead of reaching the network.
"""
import os
import urllib.request

_real = urllib.request.urlopen
_PREFIX = 'https://slack.com/api/'


def _urlopen(request, *args, **kwargs):
    url = request.full_url if hasattr(request, 'full_url') else str(request)
    if url.startswith(_PREFIX):
        port = os.environ.get('LAB_SLACK_PORT')
        if not port:
            raise OSError('lab: refusing real slack.com request')
        request.full_url = 'http://127.0.0.1:%s/api/%s' % (port, url[len(_PREFIX):])
    return _real(request, *args, **kwargs)


urllib.request.urlopen = _urlopen


# Lab-only slow host simulation: LAB_SLOW_ANSWERS=<seconds> delays the keyed-answer intake child.
import subprocess as _subprocess
import time as _time

_run = _subprocess.run


def _slow_run(*args, **kwargs):
    delay = os.environ.get('LAB_SLOW_ANSWERS')
    argv = args[0] if args else kwargs.get('args', [])
    if delay and isinstance(argv, (list, tuple)) and 'answers' in argv:
        _time.sleep(float(delay))
    return _run(*args, **kwargs)


_subprocess.run = _slow_run
