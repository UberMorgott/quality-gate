# Stack Detection and Wiring

> 15 nodes · cohesion 0.19

## Key Concepts

- **detect.ps1** (10 connections) — `gate/detect.ps1`
- **Get-Stacks()** (4 connections) — `gate/detect.ps1`
- **install.ps1** (4 connections) — `install.ps1`
- **Find-Marker()** (3 connections) — `gate/detect.ps1`
- **Get-GodotBin()** (3 connections) — `gate/detect.ps1`
- **Test-AnyFile()** (3 connections) — `gate/detect.ps1`
- **Test-GitIgnored()** (3 connections) — `gate/detect.ps1`
- **Test-GitIgnoredDir()** (3 connections) — `gate/detect.ps1`
- **Get-GoBuiltWith()** (2 connections) — `gate/detect.ps1`
- **Test-GoToolStale()** (2 connections) — `gate/detect.ps1`
- **Install-WebConfigs()** (2 connections) — `install.ps1`
- **Get-RepoRoot()** (1 connections) — `gate/detect.ps1`
- **Install-Lefthook()** (1 connections) — `install.ps1`
- **Set-AgentDoc()** (1 connections) — `install.ps1`
- **Set-StopHook()** (1 connections) — `install.ps1`

## Relationships

- [Gate Runner Internals](Gate_Runner_Internals.md) (2 shared connections)
- [Self-Test Harness](Self-Test_Harness.md) (1 shared connections)

## Source Files

- `gate/detect.ps1`
- `install.ps1`

## Audit Trail

- EXTRACTED: 39 (91%)
- INFERRED: 4 (9%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*