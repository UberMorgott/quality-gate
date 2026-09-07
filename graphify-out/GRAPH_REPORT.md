# Graph Report - quality-gate  (2026-09-07)

## Corpus Check
- 29 files · ~58,360 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 178 nodes · 207 edges · 30 communities (19 shown, 11 thin omitted)
- Extraction: 86% EXTRACTED · 14% INFERRED · 0% AMBIGUOUS · INFERRED: 29 edges (avg confidence: 0.83)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4cd50be9`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- GitHub Actions quality-gate workflow
- detect.ps1
- Coverage measures happy paths; a green suite proves nothing
- quality_gate job anchor shared by both hooks
- Greeter.cs
- selftest.ps1
- qgate wire (repo wiring, config only)
- ignoreFiles
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
- string

## God Nodes (most connected - your core abstractions)
1. `Invoke-DotnetStack()` - 10 edges
2. `.golangci.yml template` - 8 edges
3. `Get-DotnetSharedFormat()` - 7 edges
4. `Invoke-GodotStack()` - 7 edges
5. `Phase()` - 6 edges
6. `Invoke-CustomStack()` - 6 edges
7. `qgate wire (repo wiring, config only)` - 6 edges
8. `Get-ChangedPaths()` - 5 edges
9. `Fail()` - 5 edges
10. `Have()` - 5 edges

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

## Communities (30 total, 11 thin omitted)

### Community 0 - "GitHub Actions quality-gate workflow"
Cohesion: 0.12
Nodes (20): "Gate is wrong" issue template, GOTOOLCHAIN=auto unpacking races produce 'missing std package', Incoming agent reports: symptom right, cause wrong half the time, Second-engine review, Security findings (path traversal, middleware order, body limits), One entry point, stop on first failed phase, Wave mechanism: cleanup queue lives in the linter config, -Baseline adoption on a legacy codebase (+12 more)

### Community 1 - "detect.ps1"
Cohesion: 0.15
Nodes (14): Find-Marker(), Get-ChecksHash(), Get-CustomChecks(), Get-GoBuiltWith(), Get-GodotBin(), Get-Stacks(), Get-TrustedHash(), Get-TrustKey() (+6 more)

### Community 2 - "Coverage measures happy paths; a green suite proves nothing"
Cohesion: 0.17
Nodes (13): git check-ignore exit codes; --stdin batch unusable on Windows, Selftest counts 121 online / 115 offline, Coverage measures happy paths; a green suite proves nothing, Mutation check of existing tests, PowerShell reads an empty value as absence, Red-then-green verification, A right outcome does not prove the right cause (§0.1), Negative check asserts outcome + applied cause + absent cause (+5 more)

### Community 3 - "quality_gate job anchor shared by both hooks"
Cohesion: 0.17
Nodes (12): Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, qgate.deferrals.json (dated deferrals), qgate outdated, -Quiet (silent only on green), Vulnerability phase (govulncheck / npm audit), exhaustive with default-signifies-exhaustive, nolintlint: no bare or dead suppressions (+4 more)

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
Cohesion: 0.32
Nodes (16): Fail(), Get-ChangedPaths(), Get-DotnetChangedCs(), Get-DotnetEval(), Get-DotnetSharedFormat(), Get-DotnetTfms(), Get-DotnetTooNew(), Have() (+8 more)

### Community 10 - ".golangci.yml template"
Cohesion: 0.20
Nodes (10): git add --renormalize + checkout is a no-op for CRLF, Cancellability findings (context propagation), Final-write timeout created too early, Taint rules report one finding at a time and are inter-package, Unchecked errors: propagate, log-and-degrade, or join, Go stack phases, .golangci.yml template, govet disable-all plus non-default analyzer allow-list (+2 more)

### Community 11 - "Add"
Cohesion: 0.40
Nodes (4): T, Add(), main(), TestAdd()

### Community 14 - "Proto stack phases (buf)"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

## Knowledge Gaps
- **25 isolated node(s):** `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `dist/**`, `coverage/**`, `.cache/**` (+20 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **11 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `qgate wire (repo wiring, config only)` connect `qgate wire (repo wiring, config only)` to `GitHub Actions quality-gate workflow`, `.golangci.yml template`?**
  _High betweenness centrality (0.099) - this node is a cross-community bridge._
- **Why does `.golangci.yml template` connect `.golangci.yml template` to `quality_gate job anchor shared by both hooks`, `qgate wire (repo wiring, config only)`?**
  _High betweenness centrality (0.072) - this node is a cross-community bridge._
- **Why does `quality-gate (qgate)` connect `GitHub Actions quality-gate workflow` to `Coverage measures happy paths; a green suite proves nothing`?**
  _High betweenness centrality (0.049) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `.golangci.yml template` (e.g. with `Cancellability findings (context propagation)` and `Unchecked errors: propagate, log-and-degrade, or join`) actually correct?**
  _`.golangci.yml template` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 2 inferred relationships involving `Invoke-GodotStack()` (e.g. with `Get-GodotBin()` and `Test-GitIgnoredDir()`) actually correct?**
  _`Invoke-GodotStack()` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `dist/**` to the rest of the system?**
  _25 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `GitHub Actions quality-gate workflow` be split into smaller, more focused modules?**
  _Cohesion score 0.11578947368421053 - nodes in this community are weakly interconnected._