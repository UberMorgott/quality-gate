# Graph Report - quality-gate  (2026-09-26)

## Corpus Check
- 51 files · ~129,503 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 17 file(s) not represented in the graph (top: (none) 5, .toml 3, .gd 2)

## Summary
- 495 nodes · 738 edges · 60 communities (27 shown, 33 thin omitted)
- Extraction: 92% EXTRACTED · 8% INFERRED · 0% AMBIGUOUS · INFERRED: 58 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `ae030930`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- harmony.cs
- detect.ps1
- qgate wire (repo wiring, config only)
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
- install.ps1
- .Run
- gopurity/main.go
- Hud
- .Callee
- .golangci.yml template
- hooks/pre-commit
- pre-merge-commit
- Box.cs
- Bcl.csproj
- Test-GitIgnored
- Get-TrustedHash
- Get-Stacks
- "Gate is wrong" issue template
- Get-GoFuzzArgs
- Test-CppOwn
- Get-DirBytes
- Get-GoCgoExportLive

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 78 edges
2. `Invoke-DotnetStack()` - 15 edges
3. `Lookups` - 15 edges
4. `Invoke-CppStack()` - 12 edges
5. `Invoke-BaseStack()` - 12 edges
6. `Invoke-SmokeCheck()` - 12 edges
7. `Invoke-GoStackOnce()` - 11 edges
8. `Phase()` - 10 edges
9. `Fail()` - 9 edges
10. `Get-PathKey()` - 9 edges

## Surprising Connections (you probably didn't know these)
- `Set-OutdatedCache()` --calls--> `Get-PathKey()`  [INFERRED]
  selftest.ps1 → gate/detect.ps1
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml
- `Incoming agent reports: symptom right, cause wrong half the time` --semantically_similar_to--> `Second-engine review`  [INFERRED] [semantically similar]
  HANDOFF.md → PLAYBOOK.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (60 total, 33 thin omitted)

### Community 0 - "harmony.cs"
Cohesion: 0.05
Nodes (29): Attribute, Fixture, HarmonyLib, system, system_collections_generic, system_collections_immutable, system_io, system_linq (+21 more)

### Community 1 - "detect.ps1"
Cohesion: 0.08
Nodes (11): Get-CMakeGenerator(), Get-CppStaleTool(), Get-CppTidyTarget(), Get-GitIgnoredSet(), Get-GoBuiltWith(), Get-GolangciFloorGaps(), Get-GoLintGoos(), Get-GoTags() (+3 more)

### Community 2 - "qgate wire (repo wiring, config only)"
Cohesion: 0.08
Nodes (29): cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), GIT_INDEX_FILE marks that we are inside a commit, GOTOOLCHAIN=auto unpacking races produce 'missing std package', Measured git hook coverage matrix (git 2.53), Parallel commits in one worktree swallow each other's staged files, A signature-changing commit must carry its callers, Commit discipline (per module, explicit paths, consequence in message) (+21 more)

### Community 3 - ".Scan"
Cohesion: 0.17
Nodes (9): BlobReader, EntityHandle, V, HashSet, Ins, List, MethodDefinitionHandle, StackBehaviour (+1 more)

### Community 4 - "Lookups"
Cohesion: 0.10
Nodes (9): FieldInfo, FieldRef, MethodBase, MethodInfo, AccessTools, MethodInfo, ComputedPatch, Lookups (+1 more)

### Community 5 - "selftest.ps1"
Cohesion: 0.10
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
Cohesion: 0.10
Nodes (41): Fail(), Get-ChangedPaths(), Get-CppCompileDb(), Get-CppGeneratedIncludes(), Get-Descendants(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetSharedFormat() (+33 more)

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
Cohesion: 0.40
Nodes (4): ref_eslint_js, ref_eslint_plugin_vue, ref_globals, ref_typescript_eslint

### Community 26 - "CLAUDE.md"
Cohesion: 0.50
Nodes (3): Autonomy, Board, graphify

### Community 36 - "MetadataReader"
Cohesion: 0.31
Nodes (4): MetadataReader, TypeDefinitionHandle, TypeReferenceHandle, TypeSpecificationHandle

### Community 37 - ".Resolve"
Cohesion: 0.20
Nodes (5): CustomAttribute, CustomAttributeHandleCollection, Target, MethodDefinition, Target

### Community 38 - "install.ps1"
Cohesion: 0.33
Nodes (3): Test-AnyFile(), Install-WebConfigs(), Test-UsesTailwind()

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
Cohesion: 0.10
Nodes (20): git add --renormalize + checkout is a no-op for CRLF, Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, Taint rules report one finding at a time and are inter-package, Unchecked errors: propagate, log-and-degrade, or join, qgate.deferrals.json (dated deferrals), Go stack phases, qgate outdated (+12 more)

### Community 50 - "Box.cs"
Cohesion: 0.50
Nodes (3): Bcl, Box, Version

### Community 52 - "Test-GitIgnored"
Cohesion: 0.33
Nodes (6): Find-Marker(), Get-NestedRepos(), Get-OrphanProjects(), Test-GitIgnored(), Test-GitIgnoredDir(), Test-InNestedRepo()

### Community 53 - "Get-TrustedHash"
Cohesion: 0.33
Nodes (6): Get-ChecksHash(), Get-DefaultTrustStore(), Get-TrustedHash(), Get-TrustKey(), Get-TrustStore(), Test-ChecksTrusted()

### Community 54 - "Get-Stacks"
Cohesion: 0.50
Nodes (4): Get-CustomChecks(), Get-DeployEntries(), Get-GodotBin(), Get-Stacks()

### Community 55 - ""Gate is wrong" issue template"
Cohesion: 0.10
Nodes (21): "Gate is wrong" issue template, git check-ignore exit codes; --stdin batch unusable on Windows, Incoming agent reports: symptom right, cause wrong half the time, Selftest counts 121 online / 115 offline, Cancellability findings (context propagation), Coverage measures happy paths; a green suite proves nothing, Final-write timeout created too early, Mutation check of existing tests (+13 more)

## Knowledge Gaps
- **42 isolated node(s):** `Constructor`, `Enumerator`, `Getter`, `Normal`, `Setter` (+37 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 205 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **33 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `harmony.cs`, `.Scan`, `MetadataReader`, `.Resolve`, `.Run`, `.Get`, `.Callee`?**
  _High betweenness centrality (0.104) - this node is a cross-community bridge._
- **Why does `Get-PathKey()` connect `check.ps1` to `detect.ps1`, `selftest.ps1`?**
  _High betweenness centrality (0.026) - this node is a cross-community bridge._
- **Why does `Lookups` connect `Lookups` to `harmony.cs`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Are the 4 inferred relationships involving `Invoke-CppStack()` (e.g. with `Get-CMakeGenerator()` and `Get-CppTidyTarget()`) actually correct?**
  _`Invoke-CppStack()` has 4 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Constructor`, `Enumerator`, `Getter` to the rest of the system?**
  _42 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `harmony.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.05398110661268556 - nodes in this community are weakly interconnected._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.07692307692307693 - nodes in this community are weakly interconnected._