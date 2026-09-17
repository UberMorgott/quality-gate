# Graph Report - quality-gate  (2026-09-17)

## Corpus Check
- 44 files · ~104,586 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 406 nodes · 632 edges · 44 communities (19 shown, 13 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 45 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `64786fd0`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Patches.cs
- detect.ps1
- GitHub Actions quality-gate workflow
- .Scan
- Lookups
- selftest.ps1
- QGateHarmony
- extends
- package.json
- check.ps1
- .Lookup
- testing.T
- Proto stack phases (buf)
- qgate script
- errno=1455 is a page-file commit limit, not RAM exhaustion
- Modernizing autofixes can be breaking
- Run the linter without --fix
- pre-commit
- gatefixture
- python-fixture
- CLAUDE.md
- Fixture.csproj
- Game.csproj
- rust-fixture
- .GetArrayType
- Harmony.csproj
- Mod.csproj
- MetadataReader
- .CheckAttributes
- .golangci.yml template
- .Run
- quality_gate job anchor shared by both hooks

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 78 edges
2. `Lookups` - 15 edges
3. `Invoke-DotnetStack()` - 13 edges
4. `Invoke-SmokeCheck()` - 12 edges
5. `Invoke-BaseStack()` - 8 edges
6. `Invoke-CppStack()` - 8 edges
7. `Invoke-CustomStack()` - 8 edges
8. `Phase()` - 8 edges
9. `.golangci.yml template` - 8 edges
10. `Hud` - 7 edges

## Surprising Connections (you probably didn't know these)
- `Set-OutdatedCache()` --calls--> `Get-PathKey()`  [INFERRED]
  selftest.ps1 → gate/detect.ps1
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `Incoming agent reports: symptom right, cause wrong half the time` --semantically_similar_to--> `Second-engine review`  [INFERRED] [semantically similar]
  HANDOFF.md → PLAYBOOK.md
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (44 total, 13 thin omitted)

### Community 0 - "Patches.cs"
Cohesion: 0.07
Nodes (16): Fixture, MethodBase, Greeter, Hud, Health, IDamageable, Player, Unit (+8 more)

### Community 1 - "detect.ps1"
Cohesion: 0.08
Nodes (21): Find-Marker(), Get-ChecksHash(), Get-CustomChecks(), Get-DefaultTrustStore(), Get-DeployEntries(), Get-GitIgnoredSet(), Get-GoBuiltWith(), Get-GodotBin() (+13 more)

### Community 2 - "GitHub Actions quality-gate workflow"
Cohesion: 0.08
Nodes (28): git check-ignore exit codes; --stdin batch unusable on Windows, GOTOOLCHAIN=auto unpacking races produce 'missing std package', Selftest counts 121 online / 115 offline, Coverage measures happy paths; a green suite proves nothing, Mutation check of existing tests, PowerShell reads an empty value as absence, Red-then-green verification, A right outcome does not prove the right cause (§0.1) (+20 more)

### Community 3 - ".Scan"
Cohesion: 0.15
Nodes (11): BlobReader, EntityHandle, Gen, HashSet, Ins, List, MethodDefinitionHandle, MethodSignature (+3 more)

### Community 4 - "Lookups"
Cohesion: 0.08
Nodes (16): Attribute, HarmonyLib, FieldInfo, MethodInfo, AccessTools, HarmonyPatch, MethodType, Constructor (+8 more)

### Community 5 - "selftest.ps1"
Cohesion: 0.18
Nodes (3): Invoke-Smoke(), Invoke-Trust(), Set-OutdatedCache()

### Community 6 - "QGateHarmony"
Cohesion: 0.08
Nodes (13): A, Dictionary, Ins, QGateHarmony, H, ICustomAttributeTypeProvider, ISignatureTypeProvider, Msg (+5 more)

### Community 7 - "extends"
Cohesion: 0.40
Nodes (4): stylelint-config-recommended-vue/scss, stylelint-config-standard-scss, extends, ignoreFiles

### Community 8 - "package.json"
Cohesion: 0.29
Nodes (6): name, private, scripts, build-only, type-check, type

### Community 9 - "check.ps1"
Cohesion: 0.13
Nodes (32): Fail(), Get-ChangedPaths(), Get-CppCompileDb(), Get-Descendants(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetSharedFormat(), Get-DotnetTfms() (+24 more)

### Community 10 - ".Lookup"
Cohesion: 0.25
Nodes (5): Asm, IEnumerable, ImmutableArray, MethodDefinition, TypeDefinition

### Community 11 - "testing.T"
Cohesion: 0.28
Nodes (6): testing.T, TestRestoreSnapshotContinuesIdentically(), TestSameInputSameTrace(), Add(), main(), TestAdd()

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

### Community 26 - "CLAUDE.md"
Cohesion: 0.50
Nodes (3): Autonomy, Board, graphify

### Community 31 - ".GetArrayType"
Cohesion: 0.40
Nodes (3): ArrayShape, string, greeting()

### Community 36 - "MetadataReader"
Cohesion: 0.22
Nodes (6): V, MetadataReader, TypeDefinitionHandle, TypeReferenceHandle, TypeSpecificationHandle, V

### Community 37 - ".CheckAttributes"
Cohesion: 0.31
Nodes (4): CustomAttribute, CustomAttributeHandleCollection, Target, Target

### Community 38 - ".golangci.yml template"
Cohesion: 0.07
Nodes (30): "Gate is wrong" issue template, cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), GIT_INDEX_FILE marks that we are inside a commit, Measured git hook coverage matrix (git 2.53), Incoming agent reports: symptom right, cause wrong half the time, Parallel commits in one worktree swallow each other's staged files, git add --renormalize + checkout is a no-op for CRLF (+22 more)

### Community 41 - "quality_gate job anchor shared by both hooks"
Cohesion: 0.17
Nodes (12): Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, qgate.deferrals.json (dated deferrals), qgate outdated, -Quiet (silent only on green), Vulnerability phase (govulncheck / npm audit), exhaustive with default-signifies-exhaustive, nolintlint: no bare or dead suppressions (+4 more)

## Knowledge Gaps
- **38 isolated node(s):** `Autonomy`, `Board`, `graphify`, `Health`, `gatefixture` (+33 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 154 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **13 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `.Scan`, `MetadataReader`, `.CheckAttributes`, `.Run`, `.Lookup`, `.GetArrayType`?**
  _High betweenness centrality (0.057) - this node is a cross-community bridge._
- **Why does `qgate wire (repo wiring, config only)` connect `.golangci.yml template` to `GitHub Actions quality-gate workflow`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **Why does `Get-PathKey()` connect `check.ps1` to `detect.ps1`, `selftest.ps1`?**
  _High betweenness centrality (0.018) - this node is a cross-community bridge._
- **What connects `Autonomy`, `Board`, `graphify` to the rest of the system?**
  _38 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Patches.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.06951871657754011 - nodes in this community are weakly interconnected._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.07657657657657657 - nodes in this community are weakly interconnected._
- **Should `GitHub Actions quality-gate workflow` be split into smaller, more focused modules?**
  _Cohesion score 0.082010582010582 - nodes in this community are weakly interconnected._