## S1 green PR, fresh base, no review record (claim only in PR body)

### S1
HEAD row : {"actor":"fleet","reason":"route the independent review","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":{"behind_by":0},"review":{"ok":false,"basis":null,"kind":"not-qualified"}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / route the independent review)

## S2 PASS recorded by same model family as the author

### S2
HEAD row : {"actor":"fleet","reason":"route the independent review","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":{"behind_by":0},"review":{"ok":false,"basis":null,"kind":"not-qualified"}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / route the independent review)

## S3 PASS limited to the pr-body group

### S3
HEAD row : {"actor":"fleet","reason":"route the independent review","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":{"behind_by":0},"review":{"ok":false,"basis":null,"kind":"not-qualified"}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / route the independent review)

## S4 independent different-family exact-head PASS, fresh base, green

### S4
HEAD row : {"actor":"fleet","reason":"merge under the standing merge rule","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":{"behind_by":0},"review":{"ok":true,"basis":"independent-review","kind":null}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / merge under the standing merge rule)

## S5 same PR, base branch advanced one commit (behind_by 1)

### S5
HEAD row : {"actor":"fleet","reason":"update the branch; base is stale","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":{"behind_by":1},"review":{"ok":true,"basis":"independent-review","kind":null}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / update the branch; base is stale)

## S6 real owner hold filed with fm-captain-hold.sh hold (PR green with PASS)

### S6
HEAD row : {"actor":"captain","reason":"pick the API contract","hold":"delivery","tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"pick the API contract"}
saved facts: {"base_containment":{"behind_by":0},"review":{"ok":true,"basis":"independent-review","kind":null}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":1,"fleet":0,"maintainer":0,"nobody":0},"complete":true,"proven_clear":false,"captain":[{"task":"delivery","reason":"pick the API contract","hold":"delivery"}]}
RESULT: PASS (expected captain / pick the API contract)

## S7 hold answered with fm-captain-hold.sh answer --release

### S7
HEAD row : {"actor":"fleet","reason":"merge under the standing merge rule","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":{"behind_by":0},"review":{"ok":true,"basis":"independent-review","kind":null}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / merge under the standing merge rule)

## S8 explicit pause line in state/delivery.status, no hold

### S8
HEAD row : {"actor":"fleet","reason":"merge under the standing merge rule","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":{"behind_by":0},"review":{"ok":true,"basis":"independent-review","kind":null}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / merge under the standing merge rule)

## S9 recorded captain-actor verdict, no live hold

### S9
HEAD row : {"actor":"fleet","reason":"record the unresolved arbitration as a captain hold","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"fleet","reason":"record the unresolved arbitration as a captain hold"}
saved facts: {"base_containment":{"behind_by":0},"review":{"ok":false,"basis":null,"kind":"not-qualified"}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / record the unresolved arbitration as a captain hold)

## S10 adversarial: good PASS poll, then compare read goes silent (stall)

### S10 before
HEAD row : {"actor":"fleet","reason":"merge under the standing merge rule","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":{"behind_by":0},"review":{"ok":true,"basis":"independent-review","kind":null}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / merge under the standing merge rule)

### S10 after stalled compare
HEAD row : {"actor":"fleet","reason":"base freshness unknown; refresh the base comparison","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":null,"review":{"ok":true,"basis":"independent-review","kind":null}}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / base freshness unknown; refresh the base comparison)
deferred URLs: https://github.com/o/r/pull/8 

## S11 adversarial: good PASS poll, then verifier fails

### S11
HEAD row : {"actor":"fleet","reason":"PASS fact unknown; recheck the independent review","hold":null,"tasks":["delivery"]}
BASE row : {"actor":"captain","reason":"checks green; merge approval needed"}
saved facts: {"base_containment":{"behind_by":0},"review":null}
bearings --json contributions: {"known":1,"checked":1,"counts":{"captain":0,"fleet":1,"maintainer":0,"nobody":0},"complete":true,"proven_clear":true,"captain":[]}
RESULT: PASS (expected fleet / PASS fact unknown; recheck the independent review)

## S12 snapshot makes no forge or verifier call
forge+verifier log lines before=      20 after=      20; record bytes equal=yes
RESULT: PASS

## S13 poll forge calls are read-only
RESULT: PASS (every logged forge call is a GET read or pr view)
  counted api -i repos/o/r
  counted api -i repos/o/r/commits/3bd27d8a68b1fa1159269a1e3ec1edc1abc199ad/check-runs?filter=all&per_page=100
  counted api -i repos/o/r/commits/3bd27d8a68b1fa1159269a1e3ec1edc1abc199ad/statuses?per_page=100
  counted api -i repos/o/r/compare/main...3bd27d8a68b1fa1159269a1e3ec1edc1abc199ad?per_page=1
  counted api -i repos/o/r/issues/8/comments?per_page=100
  counted api -i repos/o/r/pulls/8
  counted api -i repos/o/r/pulls/8/comments?per_page=100
  counted api -i repos/o/r/pulls/8/reviews?per_page=100
  counted pr view https://github.com/o/r/pull/8 --json headRefOid,reviewDecision
  not-modified api -i -H If-None-Match: "31393cf4ab889a49" repos/o/r/pulls/8
  not-modified api -i -H If-None-Match: "39e44611f85f0134" repos/o/r/compare/main...3bd27d8a68b1fa1159269a1e3ec1edc1abc199ad?per_page=1
  not-modified api -i -H If-None-Match: "97d170e1550eee4a" repos/o/r/commits/3bd27d8a68b1fa1159269a1e3ec1edc1abc199ad/statuses?per_page=100
  not-modified api -i -H If-None-Match: "97d170e1550eee4a" repos/o/r/issues/8/comments?per_page=100
  not-modified api -i -H If-None-Match: "97d170e1550eee4a" repos/o/r/pulls/8/comments?per_page=100
  not-modified api -i -H If-None-Match: "97d170e1550eee4a" repos/o/r/pulls/8/reviews?per_page=100
  not-modified api -i -H If-None-Match: "9cf55f217f4d77ca" repos/o/r/commits/3bd27d8a68b1fa1159269a1e3ec1edc1abc199ad/check-runs?filter=all&per_page=100
  not-modified api -i -H If-None-Match: "c8367ef335596c13" repos/o/r

TOTAL FAILURES: 0
