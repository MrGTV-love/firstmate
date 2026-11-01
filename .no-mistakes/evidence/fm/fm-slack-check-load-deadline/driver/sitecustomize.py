import os, sys, json, time
from pathlib import Path
if Path(sys.argv[0]).name == 'fm_slack_watch.py' and os.environ.get('FM_LIVE_SLACK_BASE'):
    sys.path.insert(0, os.environ['FM_LIVE_BIN'])
    import fm_slack
    fm_slack.Slack.base = os.environ['FM_LIVE_SLACK_BASE']  # point the real transport at the local server
    control = Path(os.environ['FM_LIVE_CONTROL'])
    (control / 'client.pid').write_text(str(os.getpid()))
    real = fm_slack.Slack.call
    def call(self, method, **fields):  # observe only: record each request's outcome and duration
        t0 = time.monotonic()
        err = None
        try:
            return real(self, method, **fields)
        except Exception as e:
            err = str(e)
            raise
        finally:
            with open(control / 'client.jsonl', 'a') as out:
                out.write(json.dumps({'method': method, 'seconds': round(time.monotonic() - t0, 3), 'error': err}) + '\n')
    fm_slack.Slack.call = call
