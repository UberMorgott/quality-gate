# Graph Report - quality-gate  (2026-11-27)

## Corpus Check
- 65 files · ~192,380 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 23 file(s) not represented in the graph (top: .toml 8, (none) 5, .gd 2)
- WARNING: 23 of 89 files seen (26%) have no supported extractor and are missing from this graph entirely. It may look complete while representing only part of the codebase.

## Summary
- 703 nodes · 1208 edges · 54 communities (25 shown, 29 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 187 edges (avg confidence: 0.85)
- Token cost: 128,013 input · 0 output

## Graph Freshness
- Built from commit: `69c8546b`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Patches.cs
- Get-PathKey
- Invoke-CppStack
- settings
- selftest.ps1
- QGateHarmony
- extends
- package.json
- check.ps1
- steps
- go-determinism_test.go
- qgate wire (repo wiring, config only)
- Proto stack phases (buf)
- Run the linter without --fix
- gatefixture
- python-fixture
- CLAUDE.md
- Fixture.csproj
- Game.csproj
- rust-fixture
- Invoke-CustomStack
- string
- Harmony.csproj
- Mod.csproj
- rules
- SampleTests
- Invoke-BaseStack
- buf.yaml
- Hud
- jobs
- BclCore.csproj
- Box.cs
- Bcl.csproj
- Lookups
- .golangci.yml template
- Get-Stacks

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 83 edges
2. `Lookups` - 39 edges
3. `Invoke-DotnetStack()` - 21 edges
4. `Invoke-BaseStack()` - 17 edges
5. `Get-PathKey()` - 14 edges
6. `Get-Stacks()` - 14 edges
7. `Invoke-CppStack()` - 13 edges
8. `Phase()` - 12 edges
9. `Invoke-CustomStack()` - 12 edges
10. `Invoke-SmokeCheck()` - 12 edges

## Surprising Connections (you probably didn't know these)
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml
- `Unchecked errors: propagate, log-and-degrade, or join` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml
- `qgate wire (repo wiring, config only)` --references--> `.golangci.yml template`  [EXTRACTED]
  README.md → templates/.golangci.yml

## Import Cycles
- 1-file cycle: `testdata/rust-fixture/src/main.rs -> testdata/rust-fixture/src/main.rs`

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (54 total, 29 thin omitted)

### Community 0 - "Patches.cs"
Cohesion: 0.04
Nodes (18): Fixture, HarmonyLib, Greeter, HarmonyPatch, MethodType, Constructor, Enumerator, Getter (+10 more)

### Community 1 - "Get-PathKey"
Cohesion: 0.09
Nodes (19): Get-Descendants(), Get-LeakReport(), Get-PathKey(), Get-QGateHoldUntil(), Get-RepoRoot(), Get-Latest(), Get-LatestRust(), Get-ImageDiff() (+11 more)

### Community 2 - "Invoke-CppStack"
Cohesion: 0.12
Nodes (23): Fail(), Get-ChangedPaths(), Get-CppCompileDb(), Get-CppGeneratedIncludes(), Get-PdbPath(), Get-ToolTimeoutSec(), Have(), Invoke-CppStack() (+15 more)

### Community 3 - "settings"
Cohesion: 0.06
Nodes (31): generated, paths, rules, default-signifies-exhaustive, disable-all, enabled-checks, excludes, disable-all (+23 more)

### Community 5 - "selftest.ps1"
Cohesion: 0.05
Nodes (49): Format-StackOutput(), ConvertFrom-GoTestJson(), Enter-QGateLock(), Get-AegisLint(), Get-CiGoGaps(), Get-DirBytes(), Get-GoBuiltWith(), Get-GoBusyCount() (+41 more)

### Community 6 - "QGateHarmony"
Cohesion: 0.05
Nodes (5): QGateHarmony, Asm, Ins, Target, V

### Community 7 - "extends"
Cohesion: 0.40
Nodes (4): stylelint-config-recommended-vue/scss, stylelint-config-standard-scss, extends, ignoreFiles

### Community 8 - "package.json"
Cohesion: 0.29
Nodes (6): name, private, scripts, build-only, type-check, type

### Community 9 - "check.ps1"
Cohesion: 0.09
Nodes (27): Exit-GateSlot(), Get-BuildOutDirs(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetFolderFormat(), Get-DotnetFormatFailure(), Get-DotnetSharedFormat(), Get-DotnetTestFrameworkDrift() (+19 more)

### Community 10 - "steps"
Cohesion: 0.08
Nodes (23): env, QG_REF, runs-on, steps, jobs, gate, name, on (+15 more)

### Community 11 - "go-determinism_test.go"
Cohesion: 0.21
Nodes (5): TestRestoreSnapshotContinuesIdentically(), TestSameInputSameTrace(), Add(), main(), TestAdd()

### Community 13 - "qgate wire (repo wiring, config only)"
Cohesion: 0.05
Nodes (25): "Gate is wrong" issue template, GIT_INDEX_FILE marks that we are inside a commit, Selftest counts 121 online / 115 offline, Commit discipline (per module, explicit paths, consequence in message), Mutation check of existing tests, Red-then-green verification, One entry point, stop on first failed phase, Negative check asserts outcome + applied cause + absent cause (+17 more)

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

### Community 26 - "CLAUDE.md"
Cohesion: 0.50
Nodes (3): Autonomy, Board, graphify

### Community 30 - "Invoke-CustomStack"
Cohesion: 0.20
Nodes (14): Complete-CustomCheck(), Get-CpuIdleSample(), Invoke-CustomPool(), Invoke-CustomStack(), Start-CustomCheck(), Wait-CustomCheck(), ConvertTo-TrustList(), Get-ChecksHash() (+6 more)

### Community 36 - "rules"
Cohesion: 0.22
Nodes (8): extends, rules, comments, comments-indentation, document-start, line-length, new-lines, truthy

### Community 38 - "Invoke-BaseStack"
Cohesion: 0.17
Nodes (13): Get-NonGitignoreIgnoredDirs(), Get-ToolPath(), Get-UnackedVulns(), Invoke-BaseStack(), New-StagedSnapshot(), Test-VulnAcks(), Get-GitIgnoredSet(), Get-GitPaths() (+5 more)

### Community 39 - "buf.yaml"
Cohesion: 0.25
Nodes (7): breaking, use, lint, use, modules, path, version

### Community 41 - "Hud"
Cohesion: 0.29
Nodes (5): Hud, Health, IDamageable, Player, Unit

### Community 48 - "jobs"
Cohesion: 0.29
Nodes (9): name, run, use_stdin, pre-commit, jobs, pre-merge-commit, jobs, pre-push (+1 more)

### Community 49 - "BclCore.csproj"
Cohesion: 0.33
Nodes (4): netstandard2.0, Microsoft.NET.Sdk, netstandard2.0, Microsoft.NET.Sdk

### Community 50 - "Box.cs"
Cohesion: 0.50
Nodes (3): Bcl, Box, Version

### Community 60 - "Lookups"
Cohesion: 0.06
Nodes (12): AccessTools, FieldRef, ComputedPatch, Lookups, BadGetter, FallbackHelperGetter, GuardThenDerefGetter, SkirtLocalType (+4 more)

### Community 64 - ".golangci.yml template"
Cohesion: 0.08
Nodes (14): Cancellability findings (context propagation), Three rules for a machine-readable deferral file, Second-engine review, Security findings (path traversal, middleware order, body limits), Suppression needs a named reason; stale suppressions flagged, Unchecked errors: propagate, log-and-degrade, or join, qgate.deferrals.json (dated deferrals), Go stack phases (+6 more)

### Community 65 - "Get-Stacks"
Cohesion: 0.15
Nodes (13): Get-VendoredPaths(), Invoke-PowerShellStack(), Find-Marker(), Get-CustomChecks(), Get-GodotBin(), Get-OrphanProjects(), Get-PowerShellFiles(), Get-RustMetadataRaw() (+5 more)

## Knowledge Gaps
- **36 isolated node(s):** `Constructor`, `Enumerator`, `Getter`, `Normal`, `Setter` (+31 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 256 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **29 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `Patches.cs`?**
  _High betweenness centrality (0.064) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `Invoke-BaseStack()` (e.g. with `Get-GitIgnoredSet()` and `Get-GitPaths()`) actually correct?**
  _`Invoke-BaseStack()` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Constructor`, `Enumerator`, `Getter` to the rest of the system?**
  _36 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Patches.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.04440333024976873 - nodes in this community are weakly interconnected._
- **Why does `Lookups` connect `Lookups` to `Patches.cs`?**
  _High betweenness centrality (0.027) - this node is a cross-community bridge._
- **Are the 12 inferred relationships involving `Get-PathKey()` (e.g. with `check.ps1` and `Get-DotnetSharedFormat()`) actually correct?**
  _`Get-PathKey()` has 12 INFERRED edges - model-reasoned connections that need verification._
- **Should `Get-PathKey` be split into smaller, more focused modules?**
  _Cohesion score 0.0907258064516129 - nodes in this community are weakly interconnected._