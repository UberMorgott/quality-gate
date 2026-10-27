# Graph Report - quality-gate-install  (2026-10-28)

## Corpus Check
- 56 files · ~150,296 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 17 file(s) not represented in the graph (top: (none) 5, .toml 3, .gd 2)

## Summary
- 602 nodes · 994 edges · 59 communities (29 shown, 30 thin omitted)
- Extraction: 84% EXTRACTED · 16% INFERRED · 0% AMBIGUOUS · INFERRED: 158 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `9d69a9eb`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Patches.cs
- detect.ps1
- Invoke-SmokeCheck
- settings
- Lookups
- selftest.ps1
- QGateHarmony
- extends
- package.json
- check.ps1
- steps
- go-determinism_test.go
- Invoke-CustomStack
- Proto stack phases (buf)
- Run the linter without --fix
- quality_gate job anchor shared by both hooks
- gatefixture
- python-fixture
- CLAUDE.md
- Fixture.csproj
- Game.csproj
- rust-fixture
- Claude Code Stop hook (exit code 2)
- string
- Harmony.csproj
- Mod.csproj
- rules
- "Gate is wrong" issue template
- Get-Stacks
- buf.yaml
- Hud
- A right outcome does not prove the right cause (§0.1)
- GitHub Actions quality-gate workflow
- jobs
- qgate wire (repo wiring, config only)
- Box.cs
- Bcl.csproj
- .golangci.yml template
- MethodType
- Fixture
- HealthPatch
- Coverage measures happy paths; a green suite proves nothing
- Get-GodotBin

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 75 edges
2. `Invoke-GoStackOnce()` - 39 edges
3. `Invoke-DotnetStack()` - 17 edges
4. `Get-PathKey()` - 16 edges
5. `Invoke-BaseStack()` - 15 edges
6. `Lookups` - 15 edges
7. `Invoke-WebStack()` - 14 edges
8. `Phase()` - 13 edges
9. `Invoke-CppStack()` - 13 edges
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
- `Proto stack phases (buf)` --shares_data_with--> `proto fixture buf.yaml (STANDARD lint, FILE breaking)`  [INFERRED]
  README.md → testdata/proto-fixture/buf.yaml

## Import Cycles
- 1-file cycle: `testdata/rust-fixture/src/main.rs -> testdata/rust-fixture/src/main.rs`

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (59 total, 30 thin omitted)

### Community 0 - "Patches.cs"
Cohesion: 0.12
Nodes (7): HarmonyLib, HarmonyPatch, ArityPatch, HealthGetterPatch, StaminaPatch, StatusPatch, WrongTypesPatch

### Community 1 - "detect.ps1"
Cohesion: 0.12
Nodes (31): Invoke-GoStackOnce(), Get-AegisLint(), Get-CiGoGaps(), Get-DirBytes(), Get-GoBusyCount(), Get-GoCacheLimits(), Get-GoCgoExportLive(), Get-GoDeadcode() (+23 more)

### Community 2 - "Invoke-SmokeCheck"
Cohesion: 0.36
Nodes (9): Get-Descendants(), Get-LeakReport(), Get-ImageDiff(), Get-SmokeErrors(), Get-SmokeWindows(), Initialize-SmokeNative(), Invoke-SmokeCheck(), Read-SharedText() (+1 more)

### Community 3 - "settings"
Cohesion: 0.06
Nodes (31): generated, paths, rules, default-signifies-exhaustive, disable-all, enabled-checks, excludes, disable-all (+23 more)

### Community 4 - "Lookups"
Cohesion: 0.10
Nodes (4): AccessTools, FieldRef, ComputedPatch, Lookups

### Community 5 - "selftest.ps1"
Cohesion: 0.08
Nodes (11): Get-CMakeGenerator(), Get-CppStaleTool(), Get-CppTidyTarget(), Get-GoFuzzArgs(), Get-QGateEnv(), Invoke-GoFuzz(), Invoke-WithQGateEnv(), Invoke-Smoke() (+3 more)

### Community 6 - "QGateHarmony"
Cohesion: 0.05
Nodes (5): Asm, Ins, QGateHarmony, Target, V

### Community 7 - "extends"
Cohesion: 0.40
Nodes (4): stylelint-config-recommended-vue/scss, stylelint-config-standard-scss, extends, ignoreFiles

### Community 8 - "package.json"
Cohesion: 0.29
Nodes (6): name, private, scripts, build-only, type-check, type

### Community 9 - "check.ps1"
Cohesion: 0.06
Nodes (56): Exit-GateSlot(), Fail(), Get-BuildOutDirs(), Get-ChangedPaths(), Get-CppCompileDb(), Get-CppGeneratedIncludes(), Get-DotnetChangedCs(), Get-DotnetEval() (+48 more)

### Community 10 - "steps"
Cohesion: 0.08
Nodes (23): env, QG_REF, runs-on, steps, jobs, gate, name, id (+15 more)

### Community 11 - "go-determinism_test.go"
Cohesion: 0.21
Nodes (5): TestRestoreSnapshotContinuesIdentically(), TestSameInputSameTrace(), Add(), main(), TestAdd()

### Community 13 - "Invoke-CustomStack"
Cohesion: 0.31
Nodes (8): Invoke-CustomStack(), ConvertTo-TrustList(), Get-ChecksHash(), Get-DefaultTrustStore(), Get-TrustedHashes(), Get-TrustKey(), Get-TrustStore(), Test-ChecksTrusted()

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

### Community 21 - "quality_gate job anchor shared by both hooks"
Cohesion: 0.20
Nodes (6): Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, qgate.deferrals.json (dated deferrals), -Quiet (silent only on green), nolintlint: no bare or dead suppressions, quality_gate job anchor shared by both hooks

### Community 26 - "CLAUDE.md"
Cohesion: 0.50
Nodes (3): Autonomy, Board, graphify

### Community 30 - "Claude Code Stop hook (exit code 2)"
Cohesion: 0.22
Nodes (3): GIT_INDEX_FILE marks that we are inside a commit, Commit discipline (per module, explicit paths, consequence in message), Claude Code Stop hook (exit code 2)

### Community 36 - "rules"
Cohesion: 0.22
Nodes (8): extends, rules, comments, comments-indentation, document-start, line-length, new-lines, truthy

### Community 37 - ""Gate is wrong" issue template"
Cohesion: 0.25
Nodes (5): "Gate is wrong" issue template, Cancellability findings (context propagation), Second-engine review, Security findings (path traversal, middleware order, body limits), quality-gate (qgate)

### Community 38 - "Get-Stacks"
Cohesion: 0.15
Nodes (15): Find-Marker(), Get-CustomChecks(), Get-DeployEntries(), Get-NestedRepos(), Get-OrphanProjects(), Get-PowerShellFiles(), Get-Stacks(), Test-AnyFile() (+7 more)

### Community 39 - "buf.yaml"
Cohesion: 0.25
Nodes (7): breaking, use, lint, use, modules, path, version

### Community 41 - "Hud"
Cohesion: 0.23
Nodes (6): Hud, Health, IDamageable, Player, Unit, AssignablePatch

### Community 44 - "GitHub Actions quality-gate workflow"
Cohesion: 0.18
Nodes (11): One entry point, stop on first failed phase, Wave mechanism: cleanup queue lives in the linter config, -Baseline adoption on a legacy codebase, ESLint --suppress-all baseline, Rust stack phases, Marker-file stack detection, qgate.json toolchain pinning, Two levels: -Fast and -Full (+3 more)

### Community 48 - "jobs"
Cohesion: 0.38
Nodes (6): name, run, pre-commit, jobs, pre-merge-commit, jobs

### Community 50 - "Box.cs"
Cohesion: 0.50
Nodes (3): Bcl, Box, Version

### Community 52 - ".golangci.yml template"
Cohesion: 0.20
Nodes (5): Unchecked errors: propagate, log-and-degrade, or join, Go stack phases, qgate outdated, Vulnerability phase (govulncheck / npm audit), .golangci.yml template

### Community 54 - "MethodType"
Cohesion: 0.29
Nodes (7): MethodType, Constructor, Enumerator, Getter, Normal, Setter, StaticConstructor

### Community 57 - "Coverage measures happy paths; a green suite proves nothing"
Cohesion: 0.33
Nodes (5): Selftest counts 121 online / 115 offline, Mutation check of existing tests, Red-then-green verification, Negative check asserts outcome + applied cause + absent cause, qgate selftest (red-then-green on the gate itself)

### Community 58 - "Get-GodotBin"
Cohesion: 0.40
Nodes (3): Get-GoBuiltWith(), Get-GodotBin(), Test-GoToolStale()

## Knowledge Gaps
- **32 isolated node(s):** `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `net8.0`, `Microsoft.NET.Sdk`, `gatefixture` (+27 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 226 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **30 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `harmony.cs`?**
  _High betweenness centrality (0.064) - this node is a cross-community bridge._
- **Are the 30 inferred relationships involving `Invoke-GoStackOnce()` (e.g. with `Get-AegisLint()` and `Get-CiGoGaps()`) actually correct?**
  _`Invoke-GoStackOnce()` has 30 INFERRED edges - model-reasoned connections that need verification._
- **What connects `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `net8.0` to the rest of the system?**
  _32 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Patches.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.125 - nodes in this community are weakly interconnected._
- **Why does `Lookups` connect `Lookups` to `Patches.cs`?**
  _High betweenness centrality (0.013) - this node is a cross-community bridge._
- **Are the 14 inferred relationships involving `Get-PathKey()` (e.g. with `check.ps1` and `Get-DotnetSharedFormat()`) actually correct?**
  _`Get-PathKey()` has 14 INFERRED edges - model-reasoned connections that need verification._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.12298387096774194 - nodes in this community are weakly interconnected._