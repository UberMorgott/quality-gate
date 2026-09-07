# Graph Report - quality-gate  (2026-09-07)

## Corpus Check
- 30 files · ~65,583 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 182 nodes · 215 edges · 31 communities (11 shown, 11 thin omitted)
- Extraction: 86% EXTRACTED · 14% INFERRED · 0% AMBIGUOUS · INFERRED: 30 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `c99aeb53`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- GitHub Actions quality-gate workflow
- detect.ps1
- A right outcome does not prove the right cause (§0.1)
- .golangci.yml template
- Greeter.cs
- selftest.ps1
- qgate wire (repo wiring, config only)
- ignoreFiles
- package.json
- check.ps1
- "Gate is wrong" issue template
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
- string

## God Nodes (most connected - your core abstractions)
1. `Invoke-DotnetStack()` - 10 edges
2. `.golangci.yml template` - 8 edges
3. `Get-DotnetSharedFormat()` - 7 edges
4. `Invoke-CppStack()` - 7 edges
5. `Invoke-GodotStack()` - 7 edges
6. `Have()` - 6 edges
7. `Invoke-CustomStack()` - 6 edges
8. `Phase()` - 6 edges
9. `qgate wire (repo wiring, config only)` - 6 edges
10. `Get-Stacks()` - 5 edges

## Surprising Connections (you probably didn't know these)
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml
- `Incoming agent reports: symptom right, cause wrong half the time` --semantically_similar_to--> `Second-engine review`  [INFERRED] [semantically similar]
  HANDOFF.md → PLAYBOOK.md
- `Set-OutdatedCache()` --calls--> `Get-PathKey()`  [INFERRED]
  selftest.ps1 → gate/detect.ps1

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (31 total, 11 thin omitted)

### Community 0 - "GitHub Actions quality-gate workflow"
Cohesion: 0.18
Nodes (14): GOTOOLCHAIN=auto unpacking races produce 'missing std package', One entry point, stop on first failed phase, Wave mechanism: cleanup queue lives in the linter config, -Baseline adoption on a legacy codebase, ESLint --suppress-all baseline, Rust stack phases, Marker-file stack detection, Stale tool binary vs go.mod toolchain check (+6 more)

### Community 1 - "detect.ps1"
Cohesion: 0.16
Nodes (18): Find-Marker(), Get-ChecksHash(), Get-CustomChecks(), Get-DefaultTrustStore(), Get-GitIgnoredSet(), Get-GoBuiltWith(), Get-GodotBin(), Get-Stacks() (+10 more)

### Community 2 - "A right outcome does not prove the right cause (§0.1)"
Cohesion: 0.29
Nodes (8): git check-ignore exit codes; --stdin batch unusable on Windows, PowerShell reads an empty value as absence, A right outcome does not prove the right cause (§0.1), Negative check asserts outcome + applied cause + absent cause, Fail closed invariant (no check phase ran), Godot stack phases, Godot writes errors to stdout and exits 0, -Only stack selection

### Community 3 - ".golangci.yml template"
Cohesion: 0.10
Nodes (20): git add --renormalize + checkout is a no-op for CRLF, Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, Taint rules report one finding at a time and are inter-package, Unchecked errors: propagate, log-and-degrade, or join, qgate.deferrals.json (dated deferrals), Go stack phases, qgate outdated (+12 more)

### Community 6 - "qgate wire (repo wiring, config only)"
Cohesion: 0.15
Nodes (15): cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), GIT_INDEX_FILE marks that we are inside a commit, Measured git hook coverage matrix (git 2.53), Parallel commits in one worktree swallow each other's staged files, A signature-changing commit must carry its callers, Commit discipline (per module, explicit paths, consequence in message), Verify the hook actually executes (relative path silently skipped it) (+7 more)

### Community 7 - "ignoreFiles"
Cohesion: 0.25
Nodes (7): .cache/**, coverage/**, dist/**, stylelint-config-recommended-vue/scss, stylelint-config-standard-scss, extends, ignoreFiles

### Community 8 - "package.json"
Cohesion: 0.29
Nodes (6): name, private, scripts, build-only, type-check, type

### Community 9 - "check.ps1"
Cohesion: 0.33
Nodes (16): Fail(), Get-ChangedPaths(), Get-CppCompileDb(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetSharedFormat(), Get-DotnetTfms(), Get-DotnetTooNew() (+8 more)

### Community 10 - ""Gate is wrong" issue template"
Cohesion: 0.15
Nodes (13): "Gate is wrong" issue template, Incoming agent reports: symptom right, cause wrong half the time, Selftest counts 121 online / 115 offline, Cancellability findings (context propagation), Coverage measures happy paths; a green suite proves nothing, Final-write timeout created too early, Mutation check of existing tests, Red-then-green verification (+5 more)

### Community 11 - "Add"
Cohesion: 0.40
Nodes (4): T, Add(), main(), TestAdd()

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

## Knowledge Gaps
- **25 isolated node(s):** `gatefixture`, `python-fixture`, `graphify`, `net8.0`, `Microsoft.NET.Sdk` (+20 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 76 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **11 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `qgate wire (repo wiring, config only)` connect `qgate wire (repo wiring, config only)` to `GitHub Actions quality-gate workflow`, `"Gate is wrong" issue template`, `.golangci.yml template`?**
  _High betweenness centrality (0.095) - this node is a cross-community bridge._
- **Why does `.golangci.yml template` connect `.golangci.yml template` to `"Gate is wrong" issue template`, `qgate wire (repo wiring, config only)`?**
  _High betweenness centrality (0.069) - this node is a cross-community bridge._
- **Why does `quality-gate (qgate)` connect `"Gate is wrong" issue template` to `GitHub Actions quality-gate workflow`?**
  _High betweenness centrality (0.047) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `.golangci.yml template` (e.g. with `Cancellability findings (context propagation)` and `Unchecked errors: propagate, log-and-degrade, or join`) actually correct?**
  _`.golangci.yml template` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 2 inferred relationships involving `Invoke-GodotStack()` (e.g. with `Get-GodotBin()` and `Test-GitIgnoredDir()`) actually correct?**
  _`Invoke-GodotStack()` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `gatefixture`, `python-fixture`, `graphify` to the rest of the system?**
  _25 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `.golangci.yml template` be split into smaller, more focused modules?**
  _Cohesion score 0.1 - nodes in this community are weakly interconnected._