# Hook Coverage Boundaries

> 6 nodes · cohesion 0.47

## Key Concepts

- **qgate wire (repo wiring, config only)** (6 connections) — `README.md`
- **lefthook.yml template** (4 connections) — `templates/lefthook.yml`
- **cherry-pick and revert cannot be covered cheaply** (3 connections) — `HANDOFF.md`
- **Deliberately chosen boundaries (not TODOs)** (2 connections) — `HANDOFF.md`
- **Measured git hook coverage matrix (git 2.53)** (2 connections) — `HANDOFF.md`
- **lefthook swallows the exit code of pwsh -Command** (1 connections) — `templates/lefthook.yml`

## Relationships

- [Gate Philosophy and Intake](Gate_Philosophy_and_Intake.md) (2 shared connections)
- [Commit-Time Guards](Commit-Time_Guards.md) (1 shared connections)
- [Go Linting and Formatting](Go_Linting_and_Formatting.md) (1 shared connections)

## Source Files

- `HANDOFF.md`
- `README.md`
- `templates/lefthook.yml`

## Audit Trail

- EXTRACTED: 18 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*