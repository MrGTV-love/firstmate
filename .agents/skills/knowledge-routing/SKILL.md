---
name: knowledge-routing
description: Load before recording durable knowledge, captain preferences, learnings, or project memory.
user-invocable: false
metadata:
  internal: true
---

# Knowledge routing

Route durable knowledge to its most specific owner:

- Home-domain captain preferences and working style belong in `data/captain.md` after inspect-then-update.
- Captain preferences shared across secondmate domains belong in the primary home's `data/captain-shared.md` under the `secondmate-provisioning` contract.
- Fleet-local operational facts belong in curated, home-local `data/learnings.md`.
- Task-scoped notes belong with the backlog item, and investigation findings belong in the scout report.
- Knowledge useful to almost every contributor to one project belongs in that project's committed `AGENTS.md`, which only deliberate human edits extend.
- Knowledge general to every firstmate user belongs in this repo's shared tracked surface, which a user/operator home can only reach through an authorized contribution - otherwise it stays in `data/learnings.md` or a local draft for the captain.
