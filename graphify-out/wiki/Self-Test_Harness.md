# Self-Test Harness

> 9 nodes · cohesion 0.22

## Key Concepts

- **selftest.ps1** (7 connections) — `selftest.ps1`
- **Get-PathKey()** (2 connections) — `gate/detect.ps1`
- **Set-OutdatedCache()** (2 connections) — `selftest.ps1`
- **Check()** (1 connections) — `selftest.ps1`
- **Get-Summary()** (1 connections) — `selftest.ps1`
- **Invoke-Gate()** (1 connections) — `selftest.ps1`
- **Invoke-StopHook()** (1 connections) — `selftest.ps1`
- **Set-Deferrals()** (1 connections) — `selftest.ps1`
- **Set-GoFile()** (1 connections) — `selftest.ps1`

## Relationships

- [Stack Detection and Wiring](Stack_Detection_and_Wiring.md) (1 shared connections)

## Source Files

- `gate/detect.ps1`
- `selftest.ps1`

## Audit Trail

- EXTRACTED: 15 (88%)
- INFERRED: 2 (12%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*