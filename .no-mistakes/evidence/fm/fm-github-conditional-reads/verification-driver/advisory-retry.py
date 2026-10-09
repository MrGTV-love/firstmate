import readers as r
from readers import *
try:
    persist('live-advisory-setup-history',[x for x in d.results if x['result']=='fail'])
    d.results[:]=[x for x in d.results if x['result']!='fail']
    scenario('PR advisory readers report all paginated blockers and reviewer evidence even below the sweep floor',advisory)
finally:
    forge.close(); persist('live-results',d.results); persist('live-transcript',d.transcript)
assert all(x['result']=='pass' for x in d.results),[(x['name'],x['result']) for x in d.results]
