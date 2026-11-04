$ grep -n "getloadavg\|loadavg\|vm.loadavg" bin/*.py bin/*.sh bin/*.pl  (head b7cbbbac4)
bin/fm-load-report.py:13:from os.getloadavg(), os.cpu_count() and `fm-cpu-pass.sh status --json`
bin/fm-load-report.py:75:    load1, load5, load15 = os.getloadavg()
bin/fm-duration.py:342:        return os.getloadavg()[0]
bin/fm-duration-lib.sh:22:  if [ -r /proc/loadavg ]; then
bin/fm-duration-lib.sh:23:    awk '{print $1}' /proc/loadavg
bin/fm-duration-lib.sh:25:    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1}'
bin/fm-lint.sh:2060:  if [ -r /proc/loadavg ]; then
bin/fm-lint.sh:2061:    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
bin/fm-lint.sh:2063:    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'

Disposition:
- bin/fm-duration.py:342 load_now(): written beside a duration sample (record/run load_start/load_end). Data only, not admission.
- bin/fm-load-report.py: report tool. Data only.
- bin/fm-lint.sh:2060-2063: load written into the lint roots log. Data only.
- bin/fm-duration-lib.sh:22-25: fm_duration_load for the runner duration record. Data only.
- bin/fm-cpu-pass.py: no load read on head. Base 9c5874baa also has none (load term removed earlier in f77b7973c, #354); pipeline-start admits by memory reservations and a count fallback.

Live control: concurrency-fixture-head.txt case H7a, forced load average 500: 20 of 20 light pipeline starts admitted at once (counted=0), 0 wait lines.
Before/after: tests/fm-cpu-pass-admission.py run with base copy (pipeline-start-admission-base.txt) and head (pipeline-start-admission-head.txt): both "result": "pass".
