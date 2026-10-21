# Graph Report - quality-gate  (2026-10-21)

## Corpus Check
- 51 files · ~149,976 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 17 file(s) not represented in the graph (top: (none) 5, .toml 3, .gd 2)

## Summary
- 519 nodes · 910 edges · 45 communities (17 shown, 28 thin omitted)
- Extraction: 83% EXTRACTED · 17% INFERRED · 0% AMBIGUOUS · INFERRED: 158 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `c804be3d`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Patches.cs
- detect.ps1
- Invoke-SmokeCheck
- Lookups
- QGateHarmony
- extends
- package.json
- check.ps1
- go-determinism_test.go
- Proto stack phases (buf)
- Run the linter without --fix
- gatefixture
- python-fixture
- CLAUDE.md
- Fixture.csproj
- Game.csproj
- rust-fixture
- string
- Harmony.csproj
- Mod.csproj
- Get-PathKey
- Hud
- GitHub Actions quality-gate workflow
- Box.cs
- Bcl.csproj
- .golangci.yml template
- MethodType
- Fixture
- HealthPatch

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 74 edges
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
- `Set-OutdatedCache()` --calls--> `Get-PathKey()`  [INFERRED]
  selftest.ps1 → gate/detect.ps1
- `Install-WebConfigs()` --calls--> `Test-AnyFile()`  [INFERRED]
  install.ps1 → gate/detect.ps1
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml

## Import Cycles
- 1-file cycle: `testdata/rust-fixture/src/main.rs -> testdata/rust-fixture/src/main.rs`

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (45 total, 28 thin omitted)

### Community 0 - "Patches.cs"
Cohesion: 0.12
Nodes (7): HarmonyLib, HarmonyPatch, ArityPatch, HealthGetterPatch, StaminaPatch, StatusPatch, WrongTypesPatch

### Community 1 - "detect.ps1"
Cohesion: 0.05
Nodes (64): Invoke-CustomStack(), Invoke-GoStackOnce(), ConvertTo-TrustList(), Find-Marker(), Get-AegisLint(), Get-ChecksHash(), Get-CiGoGaps(), Get-CMakeGenerator() (+56 more)

### Community 2 - "Invoke-SmokeCheck"
Cohesion: 0.36
Nodes (9): Get-Descendants(), Get-LeakReport(), Get-ImageDiff(), Get-SmokeErrors(), Get-SmokeWindows(), Initialize-SmokeNative(), Invoke-SmokeCheck(), Read-SharedText() (+1 more)

### Community 4 - "Lookups"
Cohesion: 0.10
Nodes (3): AccessTools, ComputedPatch, Lookups

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
Cohesion: 0.07
Nodes (52): Exit-GateSlot(), Fail(), Get-BuildOutDirs(), Get-ChangedPaths(), Get-CppCompileDb(), Get-CppGeneratedIncludes(), Get-DotnetChangedCs(), Get-DotnetEval() (+44 more)

### Community 11 - "go-determinism_test.go"
Cohesion: 0.21
Nodes (5): TestRestoreSnapshotContinuesIdentically(), TestSameInputSameTrace(), Add(), main(), TestAdd()

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

### Community 26 - "CLAUDE.md"
Cohesion: 0.50
Nodes (3): Autonomy, Board, graphify

### Community 38 - "Get-PathKey"
Cohesion: 0.16
Nodes (8): Get-PathKey(), Get-QGateHoldUntil(), Get-RepoRoot(), Install-WebConfigs(), Set-AgentDoc(), Test-DocLink(), Test-UsesTailwind(), Set-OutdatedCache()

### Community 41 - "Hud"
Cohesion: 0.23
Nodes (6): Hud, Health, IDamageable, Player, Unit, AssignablePatch

### Community 44 - "GitHub Actions quality-gate workflow"
Cohesion: 0.05
Nodes (27): "Gate is wrong" issue template, GIT_INDEX_FILE marks that we are inside a commit, Selftest counts 121 online / 115 offline, Commit discipline (per module, explicit paths, consequence in message), Mutation check of existing tests, Red-then-green verification, Second-engine review, Security findings (path traversal, middleware order, body limits) (+19 more)

### Community 50 - "Box.cs"
Cohesion: 0.50
Nodes (3): Bcl, Box, Version

### Community 52 - ".golangci.yml template"
Cohesion: 0.09
Nodes (12): Cancellability findings (context propagation), Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, Unchecked errors: propagate, log-and-degrade, or join, qgate.deferrals.json (dated deferrals), Go stack phases, qgate outdated, -Quiet (silent only on green) (+4 more)

### Community 54 - "MethodType"
Cohesion: 0.29
Nodes (7): MethodType, Constructor, Enumerator, Getter, Normal, Setter, StaticConstructor

## Knowledge Gaps
- **32 isolated node(s):** `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `net8.0`, `Microsoft.NET.Sdk`, `gatefixture` (+27 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 177 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **28 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `harmony.cs`?**
  _High betweenness centrality (0.083) - this node is a cross-community bridge._
- **Are the 30 inferred relationships involving `Invoke-GoStackOnce()` (e.g. with `Get-AegisLint()` and `Get-CiGoGaps()`) actually correct?**
  _`Invoke-GoStackOnce()` has 30 INFERRED edges - model-reasoned connections that need verification._
- **What connects `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `net8.0` to the rest of the system?**
  _32 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Patches.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.125 - nodes in this community are weakly interconnected._
- **Why does `Lookups` connect `Lookups` to `Patches.cs`?**
  _High betweenness centrality (0.017) - this node is a cross-community bridge._
- **Are the 14 inferred relationships involving `Get-PathKey()` (e.g. with `check.ps1` and `Get-DotnetSharedFormat()`) actually correct?**
  _`Get-PathKey()` has 14 INFERRED edges - model-reasoned connections that need verification._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.05126050420168067 - nodes in this community are weakly interconnected._