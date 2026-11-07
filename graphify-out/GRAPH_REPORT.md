# Graph Report - quality-gate  (2026-11-08)

## Corpus Check
- 63 files · ~160,627 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 18 file(s) not represented in the graph (top: (none) 5, .toml 3, .gd 2)

## Summary
- 636 nodes · 1037 edges · 59 communities (27 shown, 32 thin omitted)
- Extraction: 84% EXTRACTED · 16% INFERRED · 0% AMBIGUOUS · INFERRED: 170 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `29d949c8`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Patches.cs
- detect.ps1
- Get-Stacks
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
- install.ps1
- string
- Harmony.csproj
- Mod.csproj
- rules
- SampleTests
- Coverage measures happy paths; a green suite proves nothing
- buf.yaml
- Hud
- Invoke-CppStack
- GitHub Actions quality-gate workflow
- jobs
- BclCore.csproj
- Box.cs
- Bcl.csproj
- MethodType
- Fixture
- HealthPatch

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 76 edges
2. `Invoke-DotnetStack()` - 20 edges
3. `Invoke-BaseStack()` - 16 edges
4. `Get-PathKey()` - 15 edges
5. `Lookups` - 15 edges
6. `Invoke-WebStack()` - 14 edges
7. `Invoke-CppStack()` - 13 edges
8. `Phase()` - 12 edges
9. `Invoke-SmokeCheck()` - 12 edges
10. `Get-Stacks()` - 11 edges

## Surprising Connections (you probably didn't know these)
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `.golangci.yml template` --references--> `Vulnerability phase (govulncheck / npm audit)`  [EXTRACTED]
  templates/.golangci.yml → README.md
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml
- `Unchecked errors: propagate, log-and-degrade, or join` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml

## Import Cycles
- 1-file cycle: `testdata/rust-fixture/src/main.rs -> testdata/rust-fixture/src/main.rs`

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (59 total, 32 thin omitted)

### Community 0 - "Patches.cs"
Cohesion: 0.12
Nodes (7): HarmonyLib, HarmonyPatch, ArityPatch, HealthGetterPatch, StaminaPatch, StatusPatch, WrongTypesPatch

### Community 1 - "detect.ps1"
Cohesion: 0.08
Nodes (28): ConvertFrom-GoTestJson(), Get-AegisLint(), Get-CiGoGaps(), Get-DirBytes(), Get-GitIgnoredSet(), Get-GitPaths(), Get-GoBusyCount(), Get-GoCacheLimits() (+20 more)

### Community 2 - "Get-Stacks"
Cohesion: 0.22
Nodes (10): Find-Marker(), Get-DeployEntries(), Get-NestedRepos(), Get-OrphanProjects(), Get-PowerShellFiles(), Get-Stacks(), Test-GitIgnored(), Test-GitIgnoredDir() (+2 more)

### Community 3 - "settings"
Cohesion: 0.06
Nodes (31): generated, paths, rules, default-signifies-exhaustive, disable-all, enabled-checks, excludes, disable-all (+23 more)

### Community 4 - "Lookups"
Cohesion: 0.10
Nodes (4): AccessTools, FieldRef, ComputedPatch, Lookups

### Community 5 - "selftest.ps1"
Cohesion: 0.07
Nodes (16): Get-GoBuiltWith(), Get-GoDeterministic(), Get-GoFuzzArgs(), Get-GoFuzzLimits(), Get-GolangciFloorGaps(), Get-GoleakGaps(), Get-GoSlowTestConfig(), Get-SlowGoTests() (+8 more)

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
Cohesion: 0.05
Nodes (66): Exit-GateSlot(), Fail(), Get-BuildOutDirs(), Get-ChangedPaths(), Get-Descendants(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetFolderFormat() (+58 more)

### Community 10 - "steps"
Cohesion: 0.08
Nodes (23): env, QG_REF, runs-on, steps, jobs, gate, name, on (+15 more)

### Community 11 - "go-determinism_test.go"
Cohesion: 0.21
Nodes (5): TestRestoreSnapshotContinuesIdentically(), TestSameInputSameTrace(), Add(), main(), TestAdd()

### Community 13 - "Invoke-CustomStack"
Cohesion: 0.36
Nodes (6): ConvertTo-TrustList(), Get-DefaultTrustStore(), Get-MainWorktreeRoot(), Get-TrustedHashes(), Get-TrustKey(), Get-TrustStore()

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

### Community 21 - "quality_gate job anchor shared by both hooks"
Cohesion: 0.17
Nodes (8): Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, qgate.deferrals.json (dated deferrals), qgate outdated, -Quiet (silent only on green), Vulnerability phase (govulncheck / npm audit), nolintlint: no bare or dead suppressions, quality_gate job anchor shared by both hooks

### Community 26 - "CLAUDE.md"
Cohesion: 0.50
Nodes (3): Autonomy, Board, graphify

### Community 30 - "install.ps1"
Cohesion: 0.32
Nodes (5): Test-AnyFile(), Install-WebConfigs(), Set-AgentDoc(), Test-DocLink(), Test-UsesTailwind()

### Community 36 - "rules"
Cohesion: 0.22
Nodes (8): extends, rules, comments, comments-indentation, document-start, line-length, new-lines, truthy

### Community 38 - "Coverage measures happy paths; a green suite proves nothing"
Cohesion: 0.17
Nodes (7): Selftest counts 121 online / 115 offline, Mutation check of existing tests, Red-then-green verification, Negative check asserts outcome + applied cause + absent cause, Godot stack phases, -Only stack selection, qgate selftest (red-then-green on the gate itself)

### Community 39 - "buf.yaml"
Cohesion: 0.25
Nodes (7): breaking, use, lint, use, modules, path, version

### Community 41 - "Hud"
Cohesion: 0.23
Nodes (6): Hud, Health, IDamageable, Player, Unit, AssignablePatch

### Community 42 - "Invoke-CppStack"
Cohesion: 0.28
Nodes (9): Get-CppCompileDb(), Get-CppGeneratedIncludes(), Invoke-CppStack(), Get-CMakeGenerator(), Get-CppOwnUnits(), Get-CppStaleTool(), Get-CppTidyTarget(), Test-CppOwn() (+1 more)

### Community 44 - "GitHub Actions quality-gate workflow"
Cohesion: 0.05
Nodes (24): "Gate is wrong" issue template, GIT_INDEX_FILE marks that we are inside a commit, Commit discipline (per module, explicit paths, consequence in message), Cancellability findings (context propagation), Second-engine review, Security findings (path traversal, middleware order, body limits), One entry point, stop on first failed phase, Unchecked errors: propagate, log-and-degrade, or join (+16 more)

### Community 48 - "jobs"
Cohesion: 0.29
Nodes (9): name, run, use_stdin, pre-commit, jobs, pre-merge-commit, jobs, pre-push (+1 more)

### Community 49 - "BclCore.csproj"
Cohesion: 0.33
Nodes (4): netstandard2.0, Microsoft.NET.Sdk, netstandard2.0, Microsoft.NET.Sdk

### Community 50 - "Box.cs"
Cohesion: 0.50
Nodes (3): Bcl, Box, Version

### Community 54 - "MethodType"
Cohesion: 0.29
Nodes (7): MethodType, Constructor, Enumerator, Getter, Normal, Setter, StaticConstructor

## Knowledge Gaps
- **36 isolated node(s):** `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `net8.0`, `Microsoft.NET.Sdk`, `gatefixture` (+31 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 244 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **32 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `harmony.cs`?**
  _High betweenness centrality (0.058) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `Invoke-BaseStack()` (e.g. with `Get-GitIgnoredSet()` and `Get-GitPaths()`) actually correct?**
  _`Invoke-BaseStack()` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `net8.0` to the rest of the system?**
  _36 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Patches.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.125 - nodes in this community are weakly interconnected._
- **Why does `on` connect `steps` to `check.ps1`?**
  _High betweenness centrality (0.021) - this node is a cross-community bridge._
- **Are the 13 inferred relationships involving `Get-PathKey()` (e.g. with `check.ps1` and `Get-DotnetSharedFormat()`) actually correct?**
  _`Get-PathKey()` has 13 INFERRED edges - model-reasoned connections that need verification._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.08374384236453201 - nodes in this community are weakly interconnected._