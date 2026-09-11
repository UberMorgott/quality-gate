# Graph Report - quality-gate  (2026-09-11)

## Corpus Check
- 40 files · ~84,629 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 374 nodes · 591 edges · 42 communities (19 shown, 13 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 42 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `a0ff36eb`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Patches.cs
- detect.ps1
- Coverage measures happy paths; a green suite proves nothing
- .golangci.yml template
- Lookups
- selftest.ps1
- QGateHarmony
- extends
- package.json
- check.ps1
- quality_gate job anchor shared by both hooks
- Add
- Proto stack phases (buf)
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
- .Scan
- .Lookup
- MetadataReader
- .CheckAttributes
- .Run
- Claude Code Stop hook (exit code 2)

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 78 edges
2. `Lookups` - 15 edges
3. `Invoke-SmokeCheck()` - 12 edges
4. `Invoke-DotnetStack()` - 10 edges
5. `Phase()` - 8 edges
6. `Invoke-CustomStack()` - 8 edges
7. `.golangci.yml template` - 8 edges
8. `Fail()` - 7 edges
9. `Get-DotnetSharedFormat()` - 7 edges
10. `Invoke-GodotStack()` - 7 edges

## Surprising Connections (you probably didn't know these)
- `Set-OutdatedCache()` --calls--> `Get-PathKey()`  [INFERRED]
  selftest.ps1 → gate/detect.ps1
- `Incoming agent reports: symptom right, cause wrong half the time` --semantically_similar_to--> `Second-engine review`  [INFERRED] [semantically similar]
  HANDOFF.md → PLAYBOOK.md
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (42 total, 13 thin omitted)

### Community 0 - "Patches.cs"
Cohesion: 0.07
Nodes (16): Fixture, MethodBase, Greeter, Hud, Health, IDamageable, Player, Unit (+8 more)

### Community 1 - "detect.ps1"
Cohesion: 0.12
Nodes (19): Find-Marker(), Get-ChecksHash(), Get-CustomChecks(), Get-DefaultTrustStore(), Get-DeployEntries(), Get-GitIgnoredSet(), Get-GoBuiltWith(), Get-GodotBin() (+11 more)

### Community 2 - "Coverage measures happy paths; a green suite proves nothing"
Cohesion: 0.17
Nodes (13): git check-ignore exit codes; --stdin batch unusable on Windows, Selftest counts 121 online / 115 offline, Coverage measures happy paths; a green suite proves nothing, Mutation check of existing tests, PowerShell reads an empty value as absence, Red-then-green verification, A right outcome does not prove the right cause (§0.1), Negative check asserts outcome + applied cause + absent cause (+5 more)

### Community 3 - ".golangci.yml template"
Cohesion: 0.06
Nodes (38): "Gate is wrong" issue template, cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), GOTOOLCHAIN=auto unpacking races produce 'missing std package', Measured git hook coverage matrix (git 2.53), Incoming agent reports: symptom right, cause wrong half the time, git add --renormalize + checkout is a no-op for CRLF, Cancellability findings (context propagation) (+30 more)

### Community 4 - "Lookups"
Cohesion: 0.08
Nodes (16): Attribute, HarmonyLib, FieldInfo, MethodInfo, AccessTools, HarmonyPatch, MethodType, Constructor (+8 more)

### Community 5 - "selftest.ps1"
Cohesion: 0.20
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
Cohesion: 0.18
Nodes (27): Fail(), Get-ChangedPaths(), Get-CppCompileDb(), Get-Descendants(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetSharedFormat(), Get-DotnetTfms() (+19 more)

### Community 10 - "quality_gate job anchor shared by both hooks"
Cohesion: 0.20
Nodes (10): Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, qgate.deferrals.json (dated deferrals), -Quiet (silent only on green), exhaustive with default-signifies-exhaustive, nolintlint: no bare or dead suppressions, qgate.cmd is load-bearing under the Git shell, command -v probe is false under sh.exe (+2 more)

### Community 11 - "Add"
Cohesion: 0.40
Nodes (4): testing.T, Add(), main(), TestAdd()

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

### Community 31 - ".GetArrayType"
Cohesion: 0.40
Nodes (3): ArrayShape, string, greeting()

### Community 36 - ".Scan"
Cohesion: 0.15
Nodes (11): BlobReader, EntityHandle, Gen, HashSet, Ins, List, MethodDefinitionHandle, MethodSignature (+3 more)

### Community 37 - ".Lookup"
Cohesion: 0.25
Nodes (5): Asm, IEnumerable, ImmutableArray, MethodDefinition, TypeDefinition

### Community 38 - "MetadataReader"
Cohesion: 0.22
Nodes (6): V, MetadataReader, TypeDefinitionHandle, TypeReferenceHandle, TypeSpecificationHandle, V

### Community 39 - ".CheckAttributes"
Cohesion: 0.31
Nodes (4): CustomAttribute, CustomAttributeHandleCollection, Target, Target

### Community 41 - "Claude Code Stop hook (exit code 2)"
Cohesion: 0.22
Nodes (9): GIT_INDEX_FILE marks that we are inside a commit, Parallel commits in one worktree swallow each other's staged files, A signature-changing commit must carry its callers, Commit discipline (per module, explicit paths, consequence in message), Verify the hook actually executes (relative path silently skipped it), Green-commit marker in TEMP for the Stop hook, Staged-tree guard via git write-tree, Claude Code Stop hook (exit code 2) (+1 more)

## Knowledge Gaps
- **36 isolated node(s):** `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `ignoreFiles`, `net8.0`, `Microsoft.NET.Sdk` (+31 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 134 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **13 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `.Scan`, `.Lookup`, `MetadataReader`, `.CheckAttributes`, `.Run`, `.GetArrayType`?**
  _High betweenness centrality (0.067) - this node is a cross-community bridge._
- **Why does `qgate wire (repo wiring, config only)` connect `.golangci.yml template` to `Claude Code Stop hook (exit code 2)`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `Invoke-SmokeCheck()` (e.g. with `Invoke-CustomStack()` and `Fail()`) actually correct?**
  _`Invoke-SmokeCheck()` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `ignoreFiles` to the rest of the system?**
  _36 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Patches.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.06951871657754011 - nodes in this community are weakly interconnected._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.12333333333333334 - nodes in this community are weakly interconnected._
- **Should `.golangci.yml template` be split into smaller, more focused modules?**
  _Cohesion score 0.06258890469416785 - nodes in this community are weakly interconnected._