# Graph Report - quality-gate  (2026-09-11)

## Corpus Check
- 38 files · ~75,503 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 291 nodes · 389 edges · 35 communities (13 shown, 13 thin omitted)
- Extraction: 91% EXTRACTED · 9% INFERRED · 0% AMBIGUOUS · INFERRED: 36 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `08b5f568`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- GitHub Actions quality-gate workflow
- detect.ps1
- Coverage measures happy paths; a green suite proves nothing
- .golangci.yml template
- MethodType
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

## God Nodes (most connected - your core abstractions)
1. `QGateHarmony` - 50 edges
2. `Invoke-DotnetStack()` - 10 edges
3. `.golangci.yml template` - 8 edges
4. `Get-DotnetSharedFormat()` - 7 edges
5. `Invoke-GodotStack()` - 7 edges
6. `Invoke-CppStack()` - 7 edges
7. `Invoke-CustomStack()` - 7 edges
8. `MethodType` - 7 edges
9. `Phase()` - 6 edges
10. `Have()` - 6 edges

## Surprising Connections (you probably didn't know these)
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `Incoming agent reports: symptom right, cause wrong half the time` --semantically_similar_to--> `Second-engine review`  [INFERRED] [semantically similar]
  HANDOFF.md → PLAYBOOK.md
- `Set-OutdatedCache()` --calls--> `Get-PathKey()`  [INFERRED]
  selftest.ps1 → gate/detect.ps1
- `.golangci.yml template` --references--> `Vulnerability phase (govulncheck / npm audit)`  [EXTRACTED]
  templates/.golangci.yml → README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (35 total, 13 thin omitted)

### Community 0 - "GitHub Actions quality-gate workflow"
Cohesion: 0.16
Nodes (15): GOTOOLCHAIN=auto unpacking races produce 'missing std package', One entry point, stop on first failed phase, Wave mechanism: cleanup queue lives in the linter config, -Baseline adoption on a legacy codebase, ESLint --suppress-all baseline, quality-gate (qgate), Rust stack phases, Marker-file stack detection (+7 more)

### Community 1 - "detect.ps1"
Cohesion: 0.13
Nodes (18): Find-Marker(), Get-ChecksHash(), Get-CustomChecks(), Get-DefaultTrustStore(), Get-GitIgnoredSet(), Get-GoBuiltWith(), Get-GodotBin(), Get-Stacks() (+10 more)

### Community 2 - "Coverage measures happy paths; a green suite proves nothing"
Cohesion: 0.17
Nodes (13): git check-ignore exit codes; --stdin batch unusable on Windows, Selftest counts 121 online / 115 offline, Coverage measures happy paths; a green suite proves nothing, Mutation check of existing tests, PowerShell reads an empty value as absence, Red-then-green verification, A right outcome does not prove the right cause (§0.1), Negative check asserts outcome + applied cause + absent cause (+5 more)

### Community 3 - ".golangci.yml template"
Cohesion: 0.07
Nodes (30): "Gate is wrong" issue template, cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), GIT_INDEX_FILE marks that we are inside a commit, Measured git hook coverage matrix (git 2.53), Incoming agent reports: symptom right, cause wrong half the time, Parallel commits in one worktree swallow each other's staged files, git add --renormalize + checkout is a no-op for CRLF (+22 more)

### Community 4 - "MethodType"
Cohesion: 0.06
Nodes (23): Attribute, Fixture, HarmonyLib, FieldInfo, MethodInfo, Greeter, Hud, Health (+15 more)

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
Cohesion: 0.29
Nodes (18): Fail(), Get-ChangedPaths(), Get-CppCompileDb(), Get-Descendants(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetSharedFormat(), Get-DotnetTfms() (+10 more)

### Community 10 - "quality_gate job anchor shared by both hooks"
Cohesion: 0.17
Nodes (12): Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, qgate.deferrals.json (dated deferrals), qgate outdated, -Quiet (silent only on green), Vulnerability phase (govulncheck / npm audit), exhaustive with default-signifies-exhaustive, nolintlint: no bare or dead suppressions (+4 more)

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
- **36 isolated node(s):** `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `ignoreFiles`, `net8.0`, `Microsoft.NET.Sdk` (+31 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 119 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **13 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QGateHarmony` connect `QGateHarmony` to `.GetArrayType`?**
  _High betweenness centrality (0.048) - this node is a cross-community bridge._
- **Why does `qgate wire (repo wiring, config only)` connect `.golangci.yml template` to `GitHub Actions quality-gate workflow`?**
  _High betweenness centrality (0.037) - this node is a cross-community bridge._
- **Why does `.golangci.yml template` connect `.golangci.yml template` to `quality_gate job anchor shared by both hooks`?**
  _High betweenness centrality (0.027) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `.golangci.yml template` (e.g. with `Cancellability findings (context propagation)` and `Unchecked errors: propagate, log-and-degrade, or join`) actually correct?**
  _`.golangci.yml template` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `ignoreFiles` to the rest of the system?**
  _36 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `detect.ps1` be split into smaller, more focused modules?**
  _Cohesion score 0.12681159420289856 - nodes in this community are weakly interconnected._
- **Should `.golangci.yml template` be split into smaller, more focused modules?**
  _Cohesion score 0.0735632183908046 - nodes in this community are weakly interconnected._