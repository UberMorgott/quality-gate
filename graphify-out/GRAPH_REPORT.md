# Graph Report - quality-gate  (2026-11-19)

## Corpus Check
- 65 files · ~173,400 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 18 file(s) not represented in the graph (top: (none) 5, .toml 3, .gd 2)

## Summary
- 672 nodes · 1112 edges · 56 communities (26 shown, 30 thin omitted)
- Extraction: 84% EXTRACTED · 16% INFERRED · 0% AMBIGUOUS · INFERRED: 182 edges (avg confidence: 0.85)
- Token cost: 128,013 input · 0 output

## Graph Freshness
- Built from commit: `41ca5e4f`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Patches.cs
- Invoke-BaseStack
- Invoke-CppStack
- settings
- Lookups
- selftest.ps1
- QGateHarmony
- extends
- package.json
- check.ps1
- steps
- go-determinism_test.go
- Proto stack phases (buf)
- Run the linter without --fix
- .golangci.yml template
- gatefixture
- python-fixture
- CLAUDE.md
- Fixture.csproj
- Game.csproj
- rust-fixture
- Get-PathKey
- string
- Harmony.csproj
- Mod.csproj
- rules
- SampleTests
- detect.ps1
- buf.yaml
- Hud
- Invoke-CppStack
- GitHub Actions quality-gate workflow
- jobs
- BclCore.csproj
- Box.cs
- Bcl.csproj
- Get-GodotBin

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 78 edges
2. `Lookups` - 23 edges
3. `Invoke-DotnetStack()` - 21 edges
4. `Invoke-BaseStack()` - 17 edges
5. `Get-PathKey()` - 14 edges
6. `Invoke-CppStack()` - 13 edges
7. `Get-Stacks()` - 12 edges
8. `Invoke-SmokeCheck()` - 12 edges
9. `Phase()` - 11 edges
10. `Invoke-CustomStack()` - 11 edges

## Surprising Connections (you probably didn't know these)
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml
- `Unchecked errors: propagate, log-and-degrade, or join` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml
- `Proto stack phases (buf)` --shares_data_with--> `proto fixture buf.yaml (STANDARD lint, FILE breaking)`  [INFERRED]
  README.md → testdata/proto-fixture/buf.yaml

## Import Cycles
- 1-file cycle: `testdata/rust-fixture/src/main.rs -> testdata/rust-fixture/src/main.rs`

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (56 total, 30 thin omitted)

### Community 0 - "Patches.cs"
Cohesion: 0.05
Nodes (18): Fixture, HarmonyLib, Greeter, HarmonyPatch, MethodType, Constructor, Enumerator, Getter (+10 more)

### Community 1 - "Invoke-BaseStack"
Cohesion: 0.18
Nodes (12): Get-NonGitignoreIgnoredDirs(), Get-ToolPath(), Get-UnackedVulns(), Invoke-BaseStack(), New-StagedSnapshot(), Select-BaselineFindings(), Select-BaselineHits(), Test-BaselineLine() (+4 more)

### Community 2 - "Invoke-CppStack"
Cohesion: 0.28
Nodes (9): Get-CppCompileDb(), Get-CppGeneratedIncludes(), Invoke-CppStack(), Get-CMakeGenerator(), Get-CppOwnUnits(), Get-CppStaleTool(), Get-CppTidyTarget(), Test-CppOwn() (+1 more)

### Community 3 - "settings"
Cohesion: 0.06
Nodes (31): generated, paths, rules, default-signifies-exhaustive, disable-all, enabled-checks, excludes, disable-all (+23 more)

### Community 4 - "Lookups"
Cohesion: 0.08
Nodes (6): AccessTools, FieldRef, ComputedPatch, Lookups, MisguardedPatch, OptionalPatch

### Community 5 - "selftest.ps1"
Cohesion: 0.07
Nodes (16): Get-GoCacheLimits(), Get-GoDeterministic(), Get-GoFlakyGaps(), Get-GoFuzzArgs(), Get-GoFuzzLimits(), Get-GolangciFloorGaps(), Get-GoLintGoos(), Get-SlowGoTests() (+8 more)

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
Nodes (26): Exit-GateSlot(), Get-BuildOutDirs(), Get-CpuIdleSample(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetFolderFormat(), Get-DotnetFormatFailure(), Get-DotnetSharedFormat() (+18 more)

### Community 10 - "steps"
Cohesion: 0.08
Nodes (23): env, QG_REF, runs-on, steps, jobs, gate, name, on (+15 more)

### Community 11 - "go-determinism_test.go"
Cohesion: 0.21
Nodes (5): TestRestoreSnapshotContinuesIdentically(), TestSameInputSameTrace(), Add(), main(), TestAdd()

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

### Community 21 - ".golangci.yml template"
Cohesion: 0.05
Nodes (20): "Gate is wrong" issue template, GIT_INDEX_FILE marks that we are inside a commit, Commit discipline (per module, explicit paths, consequence in message), Cancellability findings (context propagation), Three rules for a machine-readable deferral file, Second-engine review, Security findings (path traversal, middleware order, body limits), Suppression needs a named reason; stale suppressions flagged (+12 more)

### Community 26 - "CLAUDE.md"
Cohesion: 0.50
Nodes (3): Autonomy, Board, graphify

### Community 30 - "Get-PathKey"
Cohesion: 0.07
Nodes (29): Get-Descendants(), Get-LeakReport(), Invoke-CustomStack(), ConvertTo-TrustList(), Get-ChecksHash(), Get-CustomChecks(), Get-DefaultTrustStore(), Get-MainWorktreeRoot() (+21 more)

### Community 36 - "rules"
Cohesion: 0.22
Nodes (8): extends, rules, comments, comments-indentation, document-start, line-length, new-lines, truthy

### Community 38 - "detect.ps1"
Cohesion: 0.08
Nodes (35): ConvertFrom-GoTestJson(), Enter-QGateLock(), Find-Marker(), Get-AegisLint(), Get-CiGoGaps(), Get-DirBytes(), Get-GoBusyCount(), Get-GoCgoExportLive() (+27 more)

### Community 39 - "buf.yaml"
Cohesion: 0.25
Nodes (7): breaking, use, lint, use, modules, path, version

### Community 41 - "Hud"
Cohesion: 0.29
Nodes (5): Hud, Health, IDamageable, Player, Unit

### Community 42 - "Invoke-CppStack"
Cohesion: 0.15
Nodes (16): Fail(), Get-ChangedPaths(), Get-PdbPath(), Get-ToolTimeoutSec(), Get-VendoredPaths(), Have(), Invoke-DeployStack(), Invoke-GodotStack() (+8 more)

### Community 44 - "GitHub Actions quality-gate workflow"
Cohesion: 0.08
Nodes (19): Selftest counts 121 online / 115 offline, Mutation check of existing tests, Red-then-green verification, One entry point, stop on first failed phase, Negative check asserts outcome + applied cause + absent cause, Wave mechanism: cleanup queue lives in the linter config, -Baseline adoption on a legacy codebase, ESLint --suppress-all baseline (+11 more)

### Community 48 - "jobs"
Cohesion: 0.29
Nodes (9): name, run, use_stdin, pre-commit, jobs, pre-merge-commit, jobs, pre-push (+1 more)

### Community 49 - "BclCore.csproj"
Cohesion: 0.33
Nodes (4): netstandard2.0, Microsoft.NET.Sdk, netstandard2.0, Microsoft.NET.Sdk

### Community 50 - "Box.cs"
Cohesion: 0.50
Nodes (3): Bcl, Box, Version

### Community 65 - "Get-GodotBin"
Cohesion: 0.40
Nodes (3): Get-GoBuiltWith(), Get-GodotBin(), Test-GoToolStale()

## Knowledge Gaps
- **36 isolated node(s):** `gatefixture`, `python-fixture`, `net8.0`, `Microsoft.NET.Sdk`, `netstandard2.0` (+31 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 256 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **30 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `Patches.cs`?**
  _High betweenness centrality (0.058) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `Invoke-BaseStack()` (e.g. with `Get-GitIgnoredSet()` and `Get-GitPaths()`) actually correct?**
  _`Invoke-BaseStack()` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `gatefixture`, `python-fixture`, `net8.0` to the rest of the system?**
  _36 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Patches.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.04541062801932367 - nodes in this community are weakly interconnected._
- **Why does `on` connect `steps` to `check.ps1`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Are the 12 inferred relationships involving `Get-PathKey()` (e.g. with `check.ps1` and `Get-DotnetSharedFormat()`) actually correct?**
  _`Get-PathKey()` has 12 INFERRED edges - model-reasoned connections that need verification._
- **Should `settings` be split into smaller, more focused modules?**
  _Cohesion score 0.0625 - nodes in this community are weakly interconnected._