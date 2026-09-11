# Graph Report - quality-gate  (2026-09-11)

## Corpus Check
- 40 files · ~84,411 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 306 nodes · 420 edges · 36 communities (14 shown, 12 thin omitted)
- Extraction: 90% EXTRACTED · 10% INFERRED · 0% AMBIGUOUS · INFERRED: 43 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `ecf067bd`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- GitHub Actions quality-gate workflow
- detect.ps1
- "Gate is wrong" issue template
- qgate wire (repo wiring, config only)
- MethodType
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

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 50 edges
2. `Invoke-SmokeCheck()` - 12 edges
3. `Invoke-DotnetStack()` - 10 edges
4. `Phase()` - 8 edges
5. `Invoke-CustomStack()` - 8 edges
6. `.golangci.yml template` - 8 edges
7. `Fail()` - 7 edges
8. `Get-DotnetSharedFormat()` - 7 edges
9. `Invoke-GodotStack()` - 7 edges
10. `Invoke-CppStack()` - 7 edges

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

## Communities (36 total, 12 thin omitted)

### Community 0 - "GitHub Actions quality-gate workflow"
Cohesion: 0.18
Nodes (14): GOTOOLCHAIN=auto unpacking races produce 'missing std package', One entry point, stop on first failed phase, Wave mechanism: cleanup queue lives in the linter config, -Baseline adoption on a legacy codebase, ESLint --suppress-all baseline, Rust stack phases, Marker-file stack detection, Stale tool binary vs go.mod toolchain check (+6 more)

### Community 1 - "detect.ps1"
Cohesion: 0.12
Nodes (19): Find-Marker(), Get-ChecksHash(), Get-CustomChecks(), Get-DefaultTrustStore(), Get-DeployEntries(), Get-GitIgnoredSet(), Get-GoBuiltWith(), Get-GodotBin() (+11 more)

### Community 2 - ""Gate is wrong" issue template"
Cohesion: 0.10
Nodes (21): "Gate is wrong" issue template, git check-ignore exit codes; --stdin batch unusable on Windows, Incoming agent reports: symptom right, cause wrong half the time, Selftest counts 121 online / 115 offline, Cancellability findings (context propagation), Coverage measures happy paths; a green suite proves nothing, Final-write timeout created too early, Mutation check of existing tests (+13 more)

### Community 3 - "qgate wire (repo wiring, config only)"
Cohesion: 0.15
Nodes (15): cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), GIT_INDEX_FILE marks that we are inside a commit, Measured git hook coverage matrix (git 2.53), Parallel commits in one worktree swallow each other's staged files, A signature-changing commit must carry its callers, Commit discipline (per module, explicit paths, consequence in message), Verify the hook actually executes (relative path silently skipped it) (+7 more)

### Community 4 - "MethodType"
Cohesion: 0.06
Nodes (23): Attribute, Fixture, HarmonyLib, FieldInfo, MethodInfo, Greeter, Hud, Health (+15 more)

### Community 5 - "selftest.ps1"
Cohesion: 0.20
Nodes (3): Invoke-Smoke(), Invoke-Trust(), Set-OutdatedCache()

### Community 6 - "QGateHarmony"
Cohesion: 0.06
Nodes (25): A, Asm, CustomAttribute, CustomAttributeHandleCollection, Dictionary, EntityHandle, Asm, QGateHarmony (+17 more)

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

## Knowledge Gaps
- **36 isolated node(s):** `gatefixture`, `python-fixture`, `graphify`, `net8.0`, `Microsoft.NET.Sdk` (+31 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 121 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **12 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `.GetArrayType`?**
  _High betweenness centrality (0.044) - this node is a cross-community bridge._
- **Why does `qgate wire (repo wiring, config only)` connect `qgate wire (repo wiring, config only)` to `GitHub Actions quality-gate workflow`, `"Gate is wrong" issue template`, `.golangci.yml template`?**
  _High betweenness centrality (0.033) - this node is a cross-community bridge._
- **Why does `.golangci.yml template` connect `.golangci.yml template` to `"Gate is wrong" issue template`, `qgate wire (repo wiring, config only)`?**
  _High betweenness centrality (0.024) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `Invoke-SmokeCheck()` (e.g. with `Invoke-CustomStack()` and `Fail()`) actually correct?**
  _`Invoke-SmokeCheck()` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `gatefixture`, `python-fixture`, `graphify` to the rest of the system?**
  _36 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.12333333333333334 - nodes in this community are weakly interconnected._
- **Should `"Gate is wrong" issue template` be split into smaller, more focused modules?**
  _Cohesion score 0.1 - nodes in this community are weakly interconnected._