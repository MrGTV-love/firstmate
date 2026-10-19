# Real Claude hook, loopback fake provider: base 891f55e8 vs head 434776a1
Columns: scenario | provider requests | attempts | chunks | planned_chunks | failures kept | cost (source, incomplete, reported_amount)

## base
S1a result: two failed pieces beside one answered piece | 7 | 4 | 3 | null | absent | reported, absent, absent
S1b write:  two failed pieces beside one answered piece | 7 | 4 | 3 | null | absent | reported, absent, absent
S3 result: blank middle piece (adversarial) | 2 | 2 | 3 | null | absent | reported, absent, absent
S4a write: non-string content fails before planning | 0 | null | 0 | null | absent | not_called, absent, absent
S4b result: oversize beyond 16 pieces | 0 | null | 0 | null | absent | not_called, absent, absent
S4c result: never-send canary inside oversize payload | 0 | null | 0 | null | absent | not_called, absent, absent
S6a control: single ordinary reported request | 1 | 1 | 1 | null | absent | reported, absent, absent
S5 retried success: bash call, first try 500 then ok | 2 | 1 | 1 | null | absent | reported, absent, absent

## head
S1a result: two failed pieces beside one answered piece | 7 | 7 | 3 | 3 | 2 | unknown, true, 0.001
S1b write:  two failed pieces beside one answered piece | 7 | 7 | 3 | 3 | 2 | unknown, true, 0.001
S3 result: blank middle piece (adversarial) | 2 | 2 | 2 | 2 | 0 | reported, false, 0.002
S4a write: non-string content fails before planning | 0 | null | 0 | 0 | 0 | not_called, false, 0
S4b result: oversize beyond 16 pieces | 0 | null | 0 | 0 | 0 | not_called, false, 0
S4c result: never-send canary inside oversize payload | 0 | null | 0 | 0 | 0 | not_called, false, 0
S6a control: single ordinary reported request | 1 | 1 | 1 | 1 | 0 | reported, false, 0.001
S5 retried success: bash call, first try 500 then ok | 2 | 1 | 1 | 1 | 0 | reported, false, 0.001

