# Graph Report - E:\DEV\quality-gate  (2026-09-06)

## Corpus Check
- Corpus is ~37,998 words - fits in a single context window. You may not need a graph.

## Summary
- 147 nodes · 148 edges · 26 communities (19 shown, 7 thin omitted)
- Extraction: 84% EXTRACTED · 16% INFERRED · 0% AMBIGUOUS · INFERRED: 24 edges (avg confidence: 0.84)
- Token cost: 128,013 input · 0 output

## Community Hubs (Navigation)
- Gate Philosophy and Intake
- Stack Detection and Wiring
- Verification Doctrine
- Deferrals and Hook Shell Traps
- Go Linting and Formatting
- Self-Test Harness
- Commit-Time Guards
- Stylelint Configuration
- Web Fixture Manifest
- Gate Runner Internals
- Hook Coverage Boundaries
- Go Test Fixture
- Proto Stack
- Memory-Failure Reporting
- Modernizer Autofix Risk
- Web Stack Phases
- Pre-Commit Hook Body
- Go Fixture Module
- Python Fixture

## God Nodes (most connected - your core abstractions)
1. `.golangci.yml template` - 8 edges
2. `Invoke-GodotStack()` - 7 edges
3. `qgate wire (repo wiring, config only)` - 6 edges
4. `GitHub Actions quality-gate workflow` - 5 edges
5. `Get-Stacks()` - 4 edges
6. `ignoreFiles` - 4 edges
7. `Claude Code Stop hook (exit code 2)` - 4 edges
8. `lefthook.yml template` - 4 edges
9. `quality_gate job anchor shared by both hooks` - 4 edges
10. `Test-GitIgnored()` - 3 edges

## Surprising Connections (you probably didn't know these)
- `detect stacks step (monorepo-aware marker search)` --semantically_similar_to--> `Marker-file stack detection`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `QG_REF tag pin (v1), never main` --semantically_similar_to--> `qgate.json toolchain pinning`  [INFERRED] [semantically similar]
  templates/ci.yml → README.md
- `Incoming agent reports: symptom right, cause wrong half the time` --semantically_similar_to--> `Second-engine review`  [INFERRED] [semantically similar]
  HANDOFF.md → PLAYBOOK.md
- `.golangci.yml template` --references--> `Vulnerability phase (govulncheck / npm audit)`  [EXTRACTED]
  templates/.golangci.yml → README.md
- `Cancellability findings (context propagation)` --conceptually_related_to--> `.golangci.yml template`  [INFERRED]
  PLAYBOOK.md → templates/.golangci.yml

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Four doors to a false-green run, closed by one invariant** — readme_fail_closed, readme_only_flag, readme_web_stack, readme_stack_detection, playbook_right_outcome_wrong_cause [EXTRACTED 1.00]
- **Measured lefthook-on-Windows traps behind one run: line** — templates_lefthook_exit_code_trap, templates_lefthook_cmd_shim, templates_lefthook_command_v_trap, templates_lefthook_quote_stripping_trap, templates_lefthook_quality_gate_job [EXTRACTED 1.00]
- **Commit-path coverage and the staged-index guard** — handoff_hook_coverage_matrix, handoff_cherry_pick_revert_uncovered, handoff_parallel_commit_race, handoff_git_index_file_marker, readme_staged_index_guard, templates_lefthook_quality_gate_job [INFERRED 0.95]

## Communities (26 total, 7 thin omitted)

### Community 0 - "Gate Philosophy and Intake"
Cohesion: 0.12
Nodes (20): "Gate is wrong" issue template, GOTOOLCHAIN=auto unpacking races produce 'missing std package', Incoming agent reports: symptom right, cause wrong half the time, Second-engine review, Security findings (path traversal, middleware order, body limits), One entry point, stop on first failed phase, Wave mechanism: cleanup queue lives in the linter config, -Baseline adoption on a legacy codebase (+12 more)

### Community 1 - "Stack Detection and Wiring"
Cohesion: 0.19
Nodes (9): Find-Marker(), Get-GoBuiltWith(), Get-GodotBin(), Get-Stacks(), Test-AnyFile(), Test-GitIgnored(), Test-GitIgnoredDir(), Test-GoToolStale() (+1 more)

### Community 2 - "Verification Doctrine"
Cohesion: 0.17
Nodes (13): git check-ignore exit codes; --stdin batch unusable on Windows, Selftest counts 121 online / 115 offline, Coverage measures happy paths; a green suite proves nothing, Mutation check of existing tests, PowerShell reads an empty value as absence, Red-then-green verification, A right outcome does not prove the right cause (§0.1), Negative check asserts outcome + applied cause + absent cause (+5 more)

### Community 3 - "Deferrals and Hook Shell Traps"
Cohesion: 0.17
Nodes (12): Three rules for a machine-readable deferral file, Suppression needs a named reason; stale suppressions flagged, qgate.deferrals.json (dated deferrals), qgate outdated, -Quiet (silent only on green), Vulnerability phase (govulncheck / npm audit), exhaustive with default-signifies-exhaustive, nolintlint: no bare or dead suppressions (+4 more)

### Community 4 - "Go Linting and Formatting"
Cohesion: 0.20
Nodes (10): git add --renormalize + checkout is a no-op for CRLF, Cancellability findings (context propagation), Final-write timeout created too early, Taint rules report one finding at a time and are inter-package, Unchecked errors: propagate, log-and-degrade, or join, Go stack phases, .golangci.yml template, govet disable-all plus non-default analyzer allow-list (+2 more)

### Community 6 - "Commit-Time Guards"
Cohesion: 0.22
Nodes (9): GIT_INDEX_FILE marks that we are inside a commit, Parallel commits in one worktree swallow each other's staged files, A signature-changing commit must carry its callers, Commit discipline (per module, explicit paths, consequence in message), Verify the hook actually executes (relative path silently skipped it), Green-commit marker in TEMP for the Stop hook, Staged-tree guard via git write-tree, Claude Code Stop hook (exit code 2) (+1 more)

### Community 7 - "Stylelint Configuration"
Cohesion: 0.25
Nodes (7): .cache/**, coverage/**, dist/**, stylelint-config-recommended-vue/scss, stylelint-config-standard-scss, extends, ignoreFiles

### Community 8 - "Web Fixture Manifest"
Cohesion: 0.29
Nodes (6): name, private, scripts, build-only, type-check, type

### Community 9 - "Gate Runner Internals"
Cohesion: 0.60
Nodes (5): Fail(), Get-ChangedPaths(), Have(), Invoke-GodotStack(), Phase()

### Community 10 - "Hook Coverage Boundaries"
Cohesion: 0.47
Nodes (6): cherry-pick and revert cannot be covered cheaply, Deliberately chosen boundaries (not TODOs), Measured git hook coverage matrix (git 2.53), qgate wire (repo wiring, config only), lefthook.yml template, lefthook swallows the exit code of pwsh -Command

### Community 11 - "Go Test Fixture"
Cohesion: 0.40
Nodes (4): T, Add(), main(), TestAdd()

### Community 14 - "Proto Stack"
Cohesion: 0.67
Nodes (3): Cross-stack fan-out on .proto change, Proto stack phases (buf), proto fixture buf.yaml (STANDARD lint, FILE breaking)

## Knowledge Gaps
- **21 isolated node(s):** `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `dist/**`, `coverage/**`, `.cache/**` (+16 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `qgate wire (repo wiring, config only)` connect `Hook Coverage Boundaries` to `Gate Philosophy and Intake`, `Go Linting and Formatting`, `Commit-Time Guards`?**
  _High betweenness centrality (0.146) - this node is a cross-community bridge._
- **Why does `.golangci.yml template` connect `Go Linting and Formatting` to `Hook Coverage Boundaries`, `Deferrals and Hook Shell Traps`?**
  _High betweenness centrality (0.106) - this node is a cross-community bridge._
- **Why does `quality-gate (qgate)` connect `Gate Philosophy and Intake` to `Verification Doctrine`?**
  _High betweenness centrality (0.073) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `.golangci.yml template` (e.g. with `Cancellability findings (context propagation)` and `Unchecked errors: propagate, log-and-degrade, or join`) actually correct?**
  _`.golangci.yml template` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 2 inferred relationships involving `Invoke-GodotStack()` (e.g. with `Get-GodotBin()` and `Test-GitIgnoredDir()`) actually correct?**
  _`Invoke-GodotStack()` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `stylelint-config-standard-scss`, `stylelint-config-recommended-vue/scss`, `dist/**` to the rest of the system?**
  _21 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Gate Philosophy and Intake` be split into smaller, more focused modules?**
  _Cohesion score 0.11578947368421053 - nodes in this community are weakly interconnected._