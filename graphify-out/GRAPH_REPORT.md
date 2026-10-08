# Graph Report - quality-gate  (2026-10-08)

## Corpus Check
- 51 files · ~142,232 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 17 file(s) not represented in the graph (top: (none) 5, .toml 3, .gd 2)

## Summary
- 521 nodes · 826 edges · 56 communities (25 shown, 31 thin omitted)
- Extraction: 90% EXTRACTED · 10% INFERRED · 0% AMBIGUOUS · INFERRED: 82 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `d466d193`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Patches.cs
- detect.ps1
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
- GitHub Actions quality-gate workflow
- hooks/pre-commit
- pre-merge-commit
- Box.cs
- Bcl.csproj
- .golangci.yml template
- harmony.cs
- MethodType
- Fixture
- HealthPatch

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 78 edges
2. `Invoke-GoStackOnce()` - 33 edges
3. `Invoke-DotnetStack()` - 17 edges
4. `Invoke-BaseStack()` - 15 edges
5. `Lookups` - 15 edges
6. `Invoke-WebStack()` - 14 edges
7. `Phase()` - 13 edges
8. `Invoke-CppStack()` - 12 edges
9. `Invoke-SmokeCheck()` - 12 edges
10. `Fail()` - 11 edges

## Surprising Connections (you probably didn't know these)
- `Set-OutdatedCache()` --calls--> `Get-PathKey()`  [INFERRED]
  selftest.ps1 → gate/detect.ps1
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `Incoming agent reports: symptom right, cause wrong half the time` --semantically_similar_to--> `Second-engine review`  [INFERRED] [semantically similar]
  HANDOFF.md → PLAYBOOK.md
- `Install-WebConfigs()` --calls--> `Test-AnyFile()`  [INFERRED]
  install.ps1 → gate/detect.ps1

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (56 total, 31 thin omitted)

### Community 0 - "Patches.cs"
Cohesion: 0.12
Nodes (10): Attribute, HarmonyLib, system, system_reflection, HarmonyPatch, ArityPatch, HealthGetterPatch, StaminaPatch (+2 more)

### Community 1 - "detect.ps1"
Cohesion: 0.06
Nodes (56): Invoke-GoStack(), Invoke-GoStackOnce(), Invoke-WithoutHookGitEnv(), ConvertTo-TrustList(), Find-Marker(), Get-AegisLint(), Get-ChecksHash(), Get-CiGoGaps() (+48 more)

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
Cohesion: 0.07
Nodes (58): Exit-GateSlot(), Fail(), Get-BuildOutDirs(), Get-ChangedPaths(), Get-CppCompileDb(), Get-CppGeneratedIncludes(), Get-Descendants(), Get-DotnetChangedCs() (+50 more)

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
Cohesion: 0.38
Nodes (4): Install-WebConfigs(), Set-AgentDoc(), Test-DocLink(), Test-UsesTailwind()

### Community 40 - "gopurity/main.go"
Cohesion: 0.18
Nodes (9): go_pkg_fmt, go_pkg_go_ast, go_pkg_go_build, go_pkg_go_importer, go_pkg_go_parser, go_pkg_go_token, go_pkg_go_types, go_pkg_os (+1 more)

### Community 41 - "Hud"
Cohesion: 0.23
Nodes (6): Hud, Health, IDamageable, Player, Unit, AssignablePatch

### Community 42 - ".Callee"
Cohesion: 0.17
Nodes (7): Gen, IEnumerable, ImmutableArray, MethodSignature, Name, Parent, Sig

### Community 44 - "GitHub Actions quality-gate workflow"
Cohesion: 0.08
Nodes (28): git check-ignore exit codes; --stdin batch unusable on Windows, GOTOOLCHAIN=auto unpacking races produce 'missing std package', Selftest counts 121 online / 115 offline, Coverage measures happy paths; a green suite proves nothing, Mutation check of existing tests, PowerShell reads an empty value as absence, Red-then-green verification, A right outcome does not prove the right cause (§0.1) (+20 more)

### Community 50 - "Box.cs"
Cohesion: 0.50
Nodes (3): Bcl, Box, Version

### Community 52 - ".golangci.yml template"
Cohesion: 0.05
Nodes (42): "Gate is wrong" issue template, cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), GIT_INDEX_FILE marks that we are inside a commit, Measured git hook coverage matrix (git 2.53), Incoming agent reports: symptom right, cause wrong half the time, Parallel commits in one worktree swallow each other's staged files, git add --renormalize + checkout is a no-op for CRLF (+34 more)

### Community 53 - "harmony.cs"
Cohesion: 0.18
Nodes (10): system_collections_generic, system_collections_immutable, system_io, system_linq, system_reflection_emit, system_reflection_metadata, system_reflection_metadata_ecma335, system_reflection_portableexecutable (+2 more)

### Community 54 - "MethodType"
Cohesion: 0.29
Nodes (7): MethodType, Constructor, Enumerator, Getter, Normal, Setter, StaticConstructor

## Knowledge Gaps
- **42 isolated node(s):** `gatefixture`, `python-fixture`, `Autonomy`, `Board`, `graphify` (+37 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 193 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **31 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `.Scan`, `MetadataReader`, `.Resolve`, `.Run`, `.Get`, `.Callee`, `harmony.cs`?**
  _High betweenness centrality (0.093) - this node is a cross-community bridge._
- **Why does `Get-PathKey()` connect `check.ps1` to `detect.ps1`, `selftest.ps1`?**
  _High betweenness centrality (0.026) - this node is a cross-community bridge._
- **Why does `Set-OutdatedCache()` connect `selftest.ps1` to `check.ps1`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Are the 24 inferred relationships involving `Invoke-GoStackOnce()` (e.g. with `Get-AegisLint()` and `Get-CiGoGaps()`) actually correct?**
  _`Invoke-GoStackOnce()` has 24 INFERRED edges - model-reasoned connections that need verification._
- **Are the 4 inferred relationships involving `Invoke-BaseStack()` (e.g. with `Get-GitIgnoredSet()` and `Get-NestedRepos()`) actually correct?**
  _`Invoke-BaseStack()` has 4 INFERRED edges - model-reasoned connections that need verification._
- **What connects `gatefixture`, `python-fixture`, `Autonomy` to the rest of the system?**
  _42 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Patches.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.125 - nodes in this community are weakly interconnected._