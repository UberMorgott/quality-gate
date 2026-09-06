# Commit-Time Guards

> 9 nodes · cohesion 0.22

## Key Concepts

- **Claude Code Stop hook (exit code 2)** (4 connections) — `README.md`
- **Commit discipline (per module, explicit paths, consequence in message)** (3 connections) — `PLAYBOOK.md`
- **Parallel commits in one worktree swallow each other's staged files** (2 connections) — `HANDOFF.md`
- **Green-commit marker in TEMP for the Stop hook** (2 connections) — `README.md`
- **Staged-tree guard via git write-tree** (2 connections) — `README.md`
- **GIT_INDEX_FILE marks that we are inside a commit** (1 connections) — `HANDOFF.md`
- **A signature-changing commit must carry its callers** (1 connections) — `PLAYBOOK.md`
- **Verify the hook actually executes (relative path silently skipped it)** (1 connections) — `PLAYBOOK.md`
- **lefthook ai: key rejected (exits 1, Claude blocks only on 2)** (1 connections) — `templates/lefthook.yml`

## Relationships

- [Hook Coverage Boundaries](Hook_Coverage_Boundaries.md) (1 shared connections)

## Source Files

- `HANDOFF.md`
- `PLAYBOOK.md`
- `README.md`
- `templates/lefthook.yml`

## Audit Trail

- EXTRACTED: 11 (65%)
- INFERRED: 6 (35%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*