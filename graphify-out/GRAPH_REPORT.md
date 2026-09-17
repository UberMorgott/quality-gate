# Graph Report - quality-gate  (2026-09-17)

## Corpus Check
- 47 files · ~113,763 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 17 file(s) not represented in the graph (top: (none) 5, .toml 3, .gd 2)

## Summary
- 452 nodes · 670 edges · 49 communities (22 shown, 27 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 46 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `80717427`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- harmony.cs
- detect.ps1
- quality_gate job anchor shared by both hooks
- .Scan
- Lookups
- selftest.ps1
- QGateHarmony
- extends
- package.json
- check.ps1
- .Get
- go-determinism_test.go
- main.rs
- Proto stack phases (buf)
- qgate script
- errno=1455 is a page-file commit limit, not RAM exhaustion
- Modernizing autofixes can be breaking
- Run the linter without --fix
- pre-commit
- gatefixture
- python-fixture
- eslint.config.js
- CLAUDE.md
- Fixture.csproj
- Game.csproj
- rust-fixture
- string
- Harmony.csproj
- Mod.csproj
- MetadataReader
- .Resolve
- Coverage measures happy paths; a green suite proves nothing
- .Run
- gopurity/main.go
- Hud
- .Callee
- .golangci.yml template
- hooks/pre-commit
- pre-merge-commit

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 78 edges
2. `Invoke-DotnetStack()` - 15 edges
3. `Lookups` - 15 edges
4. `Invoke-SmokeCheck()` - 12 edges
5. `Invoke-BaseStack()` - 10 edges
6. `Phase()` - 8 edges
7. `Invoke-CppStack()` - 8 edges
8. `Invoke-CustomStack()` - 8 edges
9. `.golangci.yml template` - 8 edges
10. `Fail()` - 7 edges

## Surprising Connections (you probably didn't know these)
- `Set-OutdatedCache()` --calls--> `Get-PathKey()`  [INFERRED]
  selftest.ps1 → gate/detect.ps1
- `Incoming agent reports: symptom right, cause wrong half the time` --semantically_similar_to--> `Second-engine review`  [INFERRED] [semantically similar]
  HANDOFF.md → PLAYBOOK.md
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `.golangci.yml template` --references--> `Vulnerability phase (govulncheck / npm audit)`  [EXTRACTED]
  templates/.golangci.yml → README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (49 total, 27 thin omitted)

### Community 0 - "harmony.cs"
Cohesion: 0.05
Nodes (29): Attribute, Fixture, HarmonyLib, system, system_collections_generic, system_collections_immutable, system_io, system_linq (+21 more)

### Community 1 - "detect.ps1"
Cohesion: 0.07
Nodes (21): Find-Marker(), Get-ChecksHash(), Get-CustomChecks(), Get-DefaultTrustStore(), Get-DeployEntries(), Get-GitIgnoredSet(), Get-GoBuiltWith(), Get-GodotBin() (+13 more)

### Community 2 - "quality_gate job anchor shared by both hooks"
Cohesion: 0.17
Nodes (12): Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, qgate.deferrals.json (dated deferrals), qgate outdated, -Quiet (silent only on green), Vulnerability phase (govulncheck / npm audit), exhaustive with default-signifies-exhaustive, nolintlint: no bare or dead suppressions (+4 more)

### Community 3 - ".Scan"
Cohesion: 0.17
Nodes (9): BlobReader, EntityHandle, V, HashSet, Ins, List, MethodDefinitionHandle, StackBehaviour (+1 more)

### Community 4 - "Lookups"
Cohesion: 0.11
Nodes (8): FieldInfo, MethodBase, MethodInfo, AccessTools, MethodInfo, ComputedPatch, Lookups, Type

### Community 5 - "selftest.ps1"
Cohesion: 0.12
Nodes (5): Invoke-Smoke(), Invoke-Trust(), New-GlobalRepo(), Set-GoFile(), Set-OutdatedCache()

### Community 6 - "QGateHarmony"
Cohesion: 0.09
Nodes (11): ArrayShape, Dictionary, Ins, QGateHarmony, ICustomAttributeTypeProvider, ISignatureTypeProvider, Msg, OpCode (+3 more)

### Community 7 - "extends"
Cohesion: 0.40
Nodes (4): stylelint-config-recommended-vue/scss, stylelint-config-standard-scss, extends, ignoreFiles

### Community 8 - "package.json"
Cohesion: 0.29
Nodes (6): name, private, scripts, build-only, type-check, type

### Community 9 - "check.ps1"
Cohesion: 0.12
Nodes (35): Fail(), Get-ChangedPaths(), Get-CppCompileDb(), Get-Descendants(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetSharedFormat(), Get-DotnetTfms() (+27 more)

### Community 10 - ".Get"
Cohesion: 0.35
Nodes (4): A, Asm, H, TypeDefinition

### Community 11 - "go-determinism_test.go"
Cohesion: 0.21
Nodes (9): go_pkg_pgregory_net_rapid, go_pkg_reflect, go_pkg_testing, testing.T, TestRestoreSnapshotContinuesIdentically(), TestSameInputSameTrace(), Add(), main() (+1 more)

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

### Community 24 - "eslint.config.js"
Cohesion: 0.50
Nodes (3): ref_eslint_js, ref_eslint_plugin_vue, ref_typescript_eslint

### Community 26 - "CLAUDE.md"
Cohesion: 0.50
Nodes (3): Autonomy, Board, graphify

### Community 36 - "MetadataReader"
Cohesion: 0.31
Nodes (4): MetadataReader, TypeDefinitionHandle, TypeReferenceHandle, TypeSpecificationHandle

### Community 37 - ".Resolve"
Cohesion: 0.20
Nodes (5): CustomAttribute, CustomAttributeHandleCollection, Target, MethodDefinition, Target

### Community 38 - "Coverage measures happy paths; a green suite proves nothing"
Cohesion: 0.17
Nodes (13): git check-ignore exit codes; --stdin batch unusable on Windows, Selftest counts 121 online / 115 offline, Coverage measures happy paths; a green suite proves nothing, Mutation check of existing tests, PowerShell reads an empty value as absence, Red-then-green verification, A right outcome does not prove the right cause (§0.1), Negative check asserts outcome + applied cause + absent cause (+5 more)

### Community 40 - "gopurity/main.go"
Cohesion: 0.18
Nodes (9): go_pkg_fmt, go_pkg_go_ast, go_pkg_go_build, go_pkg_go_importer, go_pkg_go_parser, go_pkg_go_token, go_pkg_go_types, go_pkg_os (+1 more)

### Community 41 - "Hud"
Cohesion: 0.19
Nodes (7): Hud, Health, IDamageable, Player, Unit, AssignablePatch, HealthPatch

### Community 42 - ".Callee"
Cohesion: 0.17
Nodes (7): Gen, IEnumerable, ImmutableArray, MethodSignature, Name, Parent, Sig

### Community 44 - ".golangci.yml template"
Cohesion: 0.05
Nodes (45): "Gate is wrong" issue template, cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), GIT_INDEX_FILE marks that we are inside a commit, GOTOOLCHAIN=auto unpacking races produce 'missing std package', Measured git hook coverage matrix (git 2.53), Incoming agent reports: symptom right, cause wrong half the time, Parallel commits in one worktree swallow each other's staged files (+37 more)

## Knowledge Gaps
- **38 isolated node(s):** `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `ignoreFiles`, `net8.0`, `Microsoft.NET.Sdk` (+33 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 189 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **27 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `harmony.cs`, `.Scan`, `MetadataReader`, `.Resolve`, `.Run`, `.Get`, `.Callee`?**
  _High betweenness centrality (0.122) - this node is a cross-community bridge._
- **Why does `Lookups` connect `Lookups` to `harmony.cs`?**
  _High betweenness centrality (0.024) - this node is a cross-community bridge._
- **Why does `Get-PathKey()` connect `check.ps1` to `detect.ps1`, `selftest.ps1`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `Invoke-SmokeCheck()` (e.g. with `Invoke-CustomStack()` and `Fail()`) actually correct?**
  _`Invoke-SmokeCheck()` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `ignoreFiles` to the rest of the system?**
  _38 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `harmony.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.05398110661268556 - nodes in this community are weakly interconnected._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.07152496626180836 - nodes in this community are weakly interconnected._