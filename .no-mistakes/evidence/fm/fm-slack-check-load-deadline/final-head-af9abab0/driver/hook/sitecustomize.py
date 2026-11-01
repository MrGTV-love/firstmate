# Disposable lab hook. It only points the real transport at a local server and
# observes each request. The real Slack.call, urllib and sockets still run.
import json, os, sys, time
from pathlib import Path
if Path(sys.argv[0]).name == 'fm_slack_watch.py' and os.environ.get('FM_LIVE_SLACK_BASE'):
    sys.path.insert(0, os.environ['FM_LIVE_BIN'])
    import urllib.request
    import fm_slack
    fm_slack.Slack.base = os.environ['FM_LIVE_SLACK_BASE']
    control = Path(os.environ['FM_LIVE_CONTROL'])
    (control / 'client.pid').write_text(str(os.getpid()))
    seen = {}
    real_open = urllib.request.urlopen
    def urlopen(request, timeout=None, **kw):
        seen['timeout'] = timeout
        return real_open(request, timeout=timeout, **kw)
    urllib.request.urlopen = urlopen
    real = fm_slack.Slack.call
    def call(self, method, **fields):
        seen.pop('timeout', None)
        t0 = time.monotonic()
        err = None
        try:
            return real(self, method, **fields)
        except Exception as e:
            err = str(e)
            raise
        finally:
            with open(control / 'client.jsonl', 'a') as out:
                out.write(json.dumps({'pid': os.getpid(), 'method': method, 'socket_timeout': seen.get('timeout'),
                                      'seconds': round(time.monotonic() - t0, 3), 'error': err}) + '\n')
    fm_slack.Slack.call = call
