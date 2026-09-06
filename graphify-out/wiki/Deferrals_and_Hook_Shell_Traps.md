# Deferrals and Hook Shell Traps

> 12 nodes · cohesion 0.17

## Key Concepts

- **quality_gate job anchor shared by both hooks** (4 connections) — `templates/lefthook.yml`
- **Suppression needs a named reason; stale suppressions flagged** (3 connections) — `PLAYBOOK.md`
- **qgate.deferrals.json (dated deferrals)** (3 connections) — `README.md`
- **Three rules for a machine-readable deferral file** (2 connections) — `PLAYBOOK.md`
- **qgate outdated** (2 connections) — `README.md`
- **-Quiet (silent only on green)** (2 connections) — `README.md`
- **Vulnerability phase (govulncheck / npm audit)** (2 connections) — `README.md`
- **exhaustive with default-signifies-exhaustive** (1 connections) — `templates/.golangci.yml`
- **nolintlint: no bare or dead suppressions** (1 connections) — `templates/.golangci.yml`
- **qgate.cmd is load-bearing under the Git shell** (1 connections) — `templates/lefthook.yml`
- **command -v probe is false under sh.exe** (1 connections) — `templates/lefthook.yml`
- **lefthook strips quotes from the run: string** (1 connections) — `templates/lefthook.yml`

## Relationships

- [Go Linting and Formatting](Go_Linting_and_Formatting.md) (1 shared connections)

## Source Files

- `PLAYBOOK.md`
- `README.md`
- `templates/.golangci.yml`
- `templates/lefthook.yml`

## Audit Trail

- EXTRACTED: 17 (74%)
- INFERRED: 6 (26%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*