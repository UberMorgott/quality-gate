# Graph Report - quality-gate  (2026-09-16)

## Corpus Check
- 40 files · ~87,379 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 377 nodes · 594 edges · 37 communities (15 shown, 12 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 42 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `0f081fff`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Patches.cs
- detect.ps1
- Coverage measures happy paths; a green suite proves nothing
- qgate wire (repo wiring, config only)
- Lookups
- selftest.ps1
- QGateHarmony
- extends
- package.json
- check.ps1
- .golangci.yml template
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
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml
- `Incoming agent reports: symptom right, cause wrong half the time` --semantically_similar_to--> `Second-engine review`  [INFERRED] [semantically similar]
  HANDOFF.md → PLAYBOOK.md
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (37 total, 12 thin omitted)

### Community 0 - "Patches.cs"
Cohesion: 0.07
Nodes (16): Fixture, MethodBase, Greeter, Hud, Health, IDamageable, Player, Unit (+8 more)

### Community 1 - "detect.ps1"
Cohesion: 0.11
Nodes (19): Find-Marker(), Get-ChecksHash(), Get-CustomChecks(), Get-DefaultTrustStore(), Get-DeployEntries(), Get-GitIgnoredSet(), Get-GoBuiltWith(), Get-GodotBin() (+11 more)

### Community 2 - "Coverage measures happy paths; a green suite proves nothing"
Cohesion: 0.17
Nodes (13): git check-ignore exit codes; --stdin batch unusable on Windows, Selftest counts 121 online / 115 offline, Coverage measures happy paths; a green suite proves nothing, Mutation check of existing tests, PowerShell reads an empty value as absence, Red-then-green verification, A right outcome does not prove the right cause (§0.1), Negative check asserts outcome + applied cause + absent cause (+5 more)

### Community 3 - "qgate wire (repo wiring, config only)"
Cohesion: 0.06
Nodes (37): "Gate is wrong" issue template, cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), GIT_INDEX_FILE marks that we are inside a commit, GOTOOLCHAIN=auto unpacking races produce 'missing std package', Measured git hook coverage matrix (git 2.53), Incoming agent reports: symptom right, cause wrong half the time, Parallel commits in one worktree swallow each other's staged files (+29 more)

### Community 4 - "Lookups"
Cohesion: 0.08
Nodes (16): Attribute, HarmonyLib, FieldInfo, MethodInfo, AccessTools, HarmonyPatch, MethodType, Constructor (+8 more)

### Community 5 - "selftest.ps1"
Cohesion: 0.20
Nodes (3): Invoke-Smoke(), Invoke-Trust(), Set-OutdatedCache()

### Community 6 - "QGateHarmony"
Cohesion: 0.07
Nodes (21): A, Asm, CustomAttribute, CustomAttributeHandleCollection, Dictionary, Asm, QGateHarmony, Target (+13 more)

### Community 7 - "extends"
Cohesion: 0.40
Nodes (4): stylelint-config-recommended-vue/scss, stylelint-config-standard-scss, extends, ignoreFiles

### Community 8 - "package.json"
Cohesion: 0.29
Nodes (6): name, private, scripts, build-only, type-check, type

### Community 9 - "check.ps1"
Cohesion: 0.18
Nodes (27): Fail(), Get-ChangedPaths(), Get-CppCompileDb(), Get-Descendants(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetSharedFormat(), Get-DotnetTfms() (+19 more)

### Community 10 - ".golangci.yml template"
Cohesion: 0.10
Nodes (20): git add --renormalize + checkout is a no-op for CRLF, Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, Taint rules report one finding at a time and are inter-package, Unchecked errors: propagate, log-and-degrade, or join, qgate.deferrals.json (dated deferrals), Go stack phases, qgate outdated (+12 more)

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
Cohesion: 0.09
Nodes (20): BlobReader, EntityHandle, Ins, V, Gen, HashSet, Ins, List (+12 more)

## Knowledge Gaps
- **37 isolated node(s):** `Health`, `gatefixture`, `python-fixture`, `Autonomy`, `graphify` (+32 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 136 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **12 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `.Scan`, `.GetArrayType`?**
  _High betweenness centrality (0.066) - this node is a cross-community bridge._
- **Why does `qgate wire (repo wiring, config only)` connect `qgate wire (repo wiring, config only)` to `.golangci.yml template`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Why does `.golangci.yml template` connect `.golangci.yml template` to `qgate wire (repo wiring, config only)`?**
  _High betweenness centrality (0.016) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `Invoke-SmokeCheck()` (e.g. with `Invoke-CustomStack()` and `Fail()`) actually correct?**
  _`Invoke-SmokeCheck()` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Health`, `gatefixture`, `python-fixture` to the rest of the system?**
  _37 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Patches.cs` be split into smaller, more focused modules?**
  _Cohesion score 0.06951871657754011 - nodes in this community are weakly interconnected._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.1111111111111111 - nodes in this community are weakly interconnected._