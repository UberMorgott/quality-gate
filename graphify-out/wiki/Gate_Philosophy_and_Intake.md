# Gate Philosophy and Intake

> 20 nodes · cohesion 0.12

## Key Concepts

- **GitHub Actions quality-gate workflow** (5 connections) — `templates/ci.yml`
- **"Gate is wrong" issue template** (3 connections) — `.github/ISSUE_TEMPLATE/gate-bug.md`
- **Second-engine review** (3 connections) — `PLAYBOOK.md`
- **One entry point, stop on first failed phase** (3 connections) — `PLAYBOOK.md`
- **-Baseline adoption on a legacy codebase** (3 connections) — `README.md`
- **quality-gate (qgate)** (3 connections) — `README.md`
- **Marker-file stack detection** (3 connections) — `README.md`
- **qgate.json toolchain pinning** (3 connections) — `README.md`
- **Two levels: -Fast and -Full** (3 connections) — `README.md`
- **Per-package cleanup queue in exclusions.rules** (3 connections) — `templates/.golangci.yml`
- **Incoming agent reports: symptom right, cause wrong half the time** (2 connections) — `HANDOFF.md`
- **Security findings (path traversal, middleware order, body limits)** (2 connections) — `PLAYBOOK.md`
- **Wave mechanism: cleanup queue lives in the linter config** (2 connections) — `PLAYBOOK.md`
- **Stale tool binary vs go.mod toolchain check** (2 connections) — `README.md`
- **detect stacks step (monorepo-aware marker search)** (2 connections) — `templates/ci.yml`
- **QG_REF tag pin (v1), never main** (2 connections) — `templates/ci.yml`
- **GOTOOLCHAIN=auto unpacking races produce 'missing std package'** (1 connections) — `HANDOFF.md`
- **ESLint --suppress-all baseline** (1 connections) — `README.md`
- **Rust stack phases** (1 connections) — `README.md`
- **gosec excludes for Windows ACL-irrelevant rules** (1 connections) — `templates/.golangci.yml`

## Relationships

- [Hook Coverage Boundaries](Hook_Coverage_Boundaries.md) (2 shared connections)
- [Go Linting and Formatting](Go_Linting_and_Formatting.md) (1 shared connections)
- [Verification Doctrine](Verification_Doctrine.md) (1 shared connections)

## Source Files

- `.github/ISSUE_TEMPLATE/gate-bug.md`
- `HANDOFF.md`
- `PLAYBOOK.md`
- `README.md`
- `templates/.golangci.yml`
- `templates/ci.yml`

## Audit Trail

- EXTRACTED: 36 (75%)
- INFERRED: 12 (25%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*