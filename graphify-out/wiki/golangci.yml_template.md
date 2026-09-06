# .golangci.yml template

> God node · 8 connections · `templates/.golangci.yml`

**Community:** [Go Linting and Formatting](Go_Linting_and_Formatting.md)

## Connections by Relation

### conceptually_related_to
- Cancellability findings (context propagation) `INFERRED`
- Unchecked errors: propagate, log-and-degrade, or join `INFERRED`

### rationale_for
- node_modules/ and vendor/ excluded from linter scope `EXTRACTED`
- govet shadow deliberately not enabled (178 hits) `EXTRACTED`

### references
- [qgate wire (repo wiring, config only)](qgate_wire_%28repo_wiring%2C_config_only%29.md) `EXTRACTED`
- Vulnerability phase (govulncheck / npm audit) `EXTRACTED`
- Taint rules report one finding at a time and are inter-package `EXTRACTED`

### shares_data_with
- Go stack phases `EXTRACTED`

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*