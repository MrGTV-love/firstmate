# Backlog objectives

Every backlog item is filed against one of these objectives, or against `none` with a stated reason.
`bin/fm-tasks-axi.sh add` reads the ids from the list below and refuses an add that names none of them ([`configuration.md`](configuration.md#backlog-intake-and-closing-proofs) owns the rule).
Each line is `- <id> - <name>: <statement>`, and the helper reads only the id.

- O1 - Plan, admission and records: the plan set is ratified, every startable row is admitted with an owner, records join on the plan row id
- O2 - Case workspace and finish-line run: one Case runs in the browser through six stages
- O3 - Data in: intake, data alignment and analytics: seven upload formats reach an Observation, one cleaning treatment, organization context
- O4 - Commercial and cost: labelled estimates, credits, the cost trace, the credit ledger
- O5 - Customer data protection and first-customer gates: synthetic labels, encryption, keys and agreements, counsel rows
- O6 - Delivery engineering: review, landing, CI, guards and repo health
- O7 - Fleet operations: firstmate tooling, hosts, spend safety, storage
