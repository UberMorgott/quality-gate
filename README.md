# qgate

qgate is a stack-detecting quality gate: one command runs the applicable checks in a repository and returns a failing exit code when an enforced check fails. Git hooks gate commits and merges; a Claude Code Stop hook checks agent work before a turn ends. This guarantees enforcement of the checks actually run, not complete coverage: optional tools, advisory findings, explicit skips, and the Stop hook's retry limit are described below.

## Install / update

Requires PowerShell 7+ (`pwsh`), Git on `PATH`, and the tools for your stacks. The bootstrap installer targets Windows; it installs qgate, not language toolchains or linters.

```powershell
irm https://raw.githubusercontent.com/UberMorgott/quality-gate/main/bootstrap.ps1 | iex
cd <your-repository>
qgate wire
```

Restart existing terminals and agents after installation so they inherit `PATH`. Bootstrap updates an existing qgate clone on `PATH`; otherwise it installs under `$env:LOCALAPPDATA\quality-gate`. Set `$env:QUALITY_GATE_HOME` before bootstrap to choose the install directory. If only `$env:QGATE_HOME` is set, installation goes under its `quality-gate` subdirectory. Whenever `QGATE_HOME` is set, trust state is `$env:QGATE_HOME\trusted.json`; otherwise, on Windows, it is `%LOCALAPPDATA%\qgate\trusted.json`. Setting `QGATE_HOME` later copies the old store on first use if the destination store does not exist.

```powershell
qgate update
qgate wire
qgate where
```

`update` runs `git pull --ff-only` in the installation. Re-running bootstrap also updates it. `wire` runs [install.ps1](install.ps1): it adds stack configs, Git hooks, `.claude/settings.json` Stop wiring, and completion instructions in `AGENTS.md` and `CLAUDE.md`, then runs `-All -Full`. Existing tool configs and foreign hooks are preserved; read any integration warnings. A failed initial gate is reported but does not make `wire` itself fail. `qgate wire -CI` also adds the GitHub Actions workflow.

## Adopting on an existing codebase

If `wire` finishes RED, review `qgate -All -Full` and adopt existing debt incrementally:

- For a one-off baseline run, use `qgate -All -Baseline HEAD~`. For hooks and CI, commit `qgate.json` with `"baseline": "<commit sha>"`: use a fixed commit SHA, not a branch.
- Go lint uses `--new-from-rev <rev> --whole-files`, so touched files are checked in full. Baselines do not waive builds, tests, or vulnerability checks.
- **Frontend note:** ESLint and stylelint are NOT baseline-filtered. Use ESLint's own `eslint --suppress-all` to write `eslint-suppressions.json` and commit it; ESLint reports unused suppressions as debt is cleaned up. This does not suppress stylelint findings.
- For golangci-lint, the fallback is per-package `linters.exclusions.rules` in `.golangci.yml`; anchor each path to that package's own files and delete each rule once the package is clean. See the [template guidance](templates/.golangci.yml).

## Usage

Run from the repository or pass `-Root <path>`. Stack discovery uses marker files up to three directories deep, excluding ignored, dependency, and build directories.

### Commands

| Command | Purpose and options |
| --- | --- |
| `qgate`, `qgate run` | Check stacks selected from staged, unstaged, and untracked changes; accepts all gate flags below. |
| `qgate wire` | Wire a project; `-Target <path>` (alias `-Root`), `-NoHook` skips Git hooks only, `-NoRun` skips the initial gate, `-CI` adds CI. |
| `qgate trust` | Print and immediately authorize custom checks on this machine; `-Root <path>`, `-Remove` revokes trust. |
| `qgate outdated` | Advisory dependency/toolchain update report; `-Root <path>`, `-Summary` for a short report cached for a day; the explicit detailed report queries afresh. |
| `qgate stop-hook` | Claude Code Stop entry point; reads hook JSON from stdin and uses `CLAUDE_PROJECT_DIR` or the current Git root. |
| `qgate hold [on\|off\|status]` | Pause the Stop hook for a background writer; default `on`, `-Minutes 1..120` (default 15), `-Root <path>`. |
| `qgate release` | Alias for `hold off`; accepts the same flags. |
| `qgate global [on\|off\|status]` | Manage global `core.hooksPath`; default `status`, refuses to replace another global hook directory. |
| `qgate update` | Fast-forward the installed clone; concurrent updates are serialized. |
| `qgate where` | Print install path, commit, resolved command, and tool versions or missing-tool status. |
| `qgate selftest` | Run the gate's failure/pass fixtures; `-Only <sections>`, `-Sequential`, `-Exact`, `-SectionTimeoutSec <seconds>` (1500), `-Throttle <jobs>` (4). |
| `qgate help` | Show CLI help; aliases `-h`, `-?`, `--help`, `/?`. |

Self-test sections: `detect`, `go`, `go2`, `core`, `wiring`, `rust`, `dotnet`, `dotnet2`, `dotnet3`, `proto`, `godot`, `hooks`, `custom`, `cpp`, `base`, `web`, `bootstrap`. Naming `go` or `dotnet` includes its numbered parts unless `-Exact` is used.

### Gate flags

| Flag | Effect |
| --- | --- |
| `-All` | Select every detected stack regardless of Git changes; does not imply `-Full`. |
| `-Fast` | Use the fast lane and suppress web bundling. |
| `-Full` | Add full checks; wins if combined with `-Fast`. |
| `-Only <stack[,stack]>` | Select named stacks regardless of changes; use e.g. `-Only "go,web"`. |
| `-Quiet` | Suppress a passing report except selected operational warnings; retain the failure report. |
| `-Why` | Show stack markers and absent stacks; also show resolved Harmony patch targets. |
| `-Baseline <rev>` | Filter supported diagnostics against a Git revision; overrides `qgate.json`'s baseline. |
| `-Mutate` | Opt into advisory Go mutation testing with gremlins. |
| `-Fix` | Apply `gofmt -w` and available `golangci-lint --fix`, then check normally; hooks never request this. |
| `-Root <path>` | Choose the repository; defaults to the current Git root. |
| `-Sarif <file>` | Also write SARIF 2.1.0 from the printed report; `-Quiet` can leave a passing report empty. |
| `-Parallel` | Run independent Go, web, Rust, .NET, C/C++, and Godot stacks concurrently. |

`-Only` accepts `base`, `go`, `web`, `rust`, `proto`, `godot`, `dotnet`, `cpp`, `custom`, `deploy`, and detected `python`. An unknown or absent stack fails. Python checks are unimplemented, so `-Only python` fails for lack of checks. Unity-generated `.csproj` files are likewise detected but skipped.

### Tiers, hooks, and results

The fast lane runs local checks and shorter Go tests. Full adds race/vulnerability checks, generation drift, heavier builds/tests, and configured full checks. Bare `qgate` does **not** enable full-only checks, but does run web bundling when a build script exists; use `-Fast` to omit bundling. Root-level changes or changes outside a stack directory select all stacks; proto changes also widen selection because generated code crosses stacks.

- Pre-commit and pre-merge-commit run `qgate -All -Full -Quiet` (`qgate.cmd` under Git's Windows shell), through Lefthook when available or direct hooks otherwise. Git cherry-pick/revert do not invoke these hooks.
- Only Claude Code gets an enforcing Stop hook. Codex and other agents get only the `AGENTS.md` instruction block; nothing enforces that block. The Claude Code Stop hook runs `-Fast -Quiet`, adding `-All` when HEAD has no matching last-green record. It blocks three consecutive failures, then allows the next stop with a warning; a passing run resets the counter. It is not an unconditional completion lock.
- `hold` or `QGATE_HOLD=1`, `true`, or `yes` skips the Stop gate while a background writer works; `release` ends the hold. Commits remain gated.
- No hold needed when Claude Code lists a running `subagent`, `teammate`, or `workflow` in the Stop input's `background_tasks`: a failure is then reported, not blocking. The first stop with none still running is gated. Background `shell`/`monitor` tasks do not count.
- Global hooks run full checks: a repository with `qgate.json` is enforced; an unwired repository without it is advisory. The dispatcher first runs the repository's own `.git/hooks/<name>` or, if absent, `.husky/<name>`. A repo-local `core.hooksPath` (e.g. husky or `.githooks`) bypasses the global dispatcher entirely. `.qgate-off` or `enabled: false` opts out of the global dispatcher only.
- Agents should run `qgate` after changes and `qgate -All -Full` before claiming full verification, report the command/result, and treat skipped coverage explicitly.

On Windows, call the gate from Lefthook via `pwsh -File <script>` or copy the [template's `run:` line](templates/lefthook.yml). `pwsh -Command "..."` and `cmd /c` lose the exit code, so a failure reports success (verified with Lefthook 2.1.12).

Gate exit codes: `0` means no enforced failure, `1` means failure; Stop hook `2` blocks the turn. CLI unknown commands and invalid hold/global actions return `64`; selftest uses `2` for unknown sections, and `update` can propagate Git's exit code. A `0` may mean no changes/no known stack or intentionally deferred custom/deploy/base checks, not that every listed check ran. Other zero-phase runs fail.

`[FAIL]` normally skips later phases/stacks; .NET whitespace failures allow later checks to continue. `[WARN]` is advisory, `[SKIP]` means no verification, and `[UNKNOWN]` means a tool could not establish a result. A run with any `[SKIP]` ends with a `[WARN] skipped -- N checks did not run` block listing each with its reason (not under `-Quiet` on a green run; exit code unchanged). `qgate.json` `strictSkips` turns those skips into a full-level `[FAIL]`. Reports can truncate detailed findings; run the named tool directly for its complete output. Builds, caches, tests, and `buf generate` can write files even without `-Fix`.

## Project configuration

Place one optional `qgate.json` at the repository root. Tool-specific rules remain in their native config files.

```json
{
  "stopHook": true,
  "checks": [
    { "name": "integration", "run": "go test -tags=integration ./...", "level": "full", "timeoutSec": 600 }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `checks` | Array of custom checks: unique `name` matching `^[a-z0-9][a-z0-9._-]*$`, `run` command or `smoke` object, `level` (`fast` or default `full`), positive `timeoutSec` (default 600). |
| `baseline` | Git revision for existing-debt adoption, including hooks; use a fixed commit SHA, not a branch. |
| `tools` | Exact version pins for `go`, `golangci-lint`, `cargo`, `node`, `buf`, `gdformat`, `gdlint`, `gdtoolkit`, `godot`; mismatches warn in fast and fail in full. |
| `strictSkips` | Opt-in, full level only (hooks included): `true` fails the run on any `[SKIP]`; an array (`["typos", "vuln", "tidy"]`) fails only skips whose line starts with a listed check name. Skips caused by an earlier failure are not counted. |
| `stopHook` | `false` makes `wire` omit/remove its Claude Code Stop hook; re-run `wire` after changing it. |
| `enabled` | `false` disables the global hook dispatcher for this repository. |
| `timeouts.godot` | Positive per-process timeout in seconds; default 600. |
| `go.lintGoos` | Array of extra GOOS targets for full vet/lint; host target is omitted and cross-target runs disable cgo. |
| `go.deterministic` | Array of root-relative package directories for purity/property-test advisories. |
| `go.flaky` | `true` or options: `count` (20; 1..500), `budget` seconds (180; 10..3600), `cpu` (`"1,2"`), `race` (true), `fail` (false), `packages` (root-relative directories; otherwise changed test packages). |
| `dotnet` | `sonar: true` enables cached Sonar analyzers; `inspectcode: true` enables JetBrains inspection; `testRunner: "fail"` makes executable test-runner failures blocking. |
| `harmony.assemblies` | Additional assembly path/glob array, with `%VAR%` expansion and recursive `**`; findings in these other assemblies are advisory. |
| `deploy` | Array of `{ "built": "path", "deployed": "path" }` pairs; root-relative or absolute paths with `%VAR%` expansion, compared in full runs without trust. |

Custom commands execute in declaration order from the repository root using `pwsh -NoProfile -Command`; nonzero exit, timeout, or a detected leaked child process fails the check (leak detection is Windows-only). Before running `qgate trust`, review the commands: trust prints and authorizes them immediately, without a confirmation prompt. Trust is per machine and repository path, not committed; changed names, commands, levels, timeouts, or smoke definitions require re-trust. Untrusted checks are skipped. `wire` never grants trust.

A `smoke` check replaces `run`, is full-only and Windows-only, and requires `exe` plus `stages: [{ "name": "ready", "ready": "log regex" }]`. Optional smoke keys: `args`, `env`, `cwd`, `log`, `closeSec` (15), `errorPattern`, `ignorePattern`, `repeatLimit` (10); stage keys: `holdSec`, `baseline` (PNG path), `tolerance` (0.01). `{dataDir}` and `QGATE_DATA_DIR` provide a fresh directory the application must explicitly use; they do not isolate an application that ignores them. Logs/screenshots are retained in the reported run directory.

Baseline filtering covers changed-line diagnostics for typos, repository linters, clang-tidy/cppcheck; Go lint and .NET formatting use changed whole files. It does not waive builds, tests, or vulnerability checks. Separate `qgate.deferrals.json` arrays can defer `dependencies` entries (`name`, `until`, `reason`) or acknowledge `vulnerabilities` (`id`, `until`, `reason`), with `until` as `YYYY-MM-DD`; vulnerability acknowledgements apply to govulncheck, OSV, and NuGet scans, not npm audit.

## Checks by stack

Names below match printed phase/advisory labels; angle-bracket suffixes stand for runtime values. **Fast** checks also run in full; **full** requires `-Full`; **advisory** findings do not fail the gate unless stated. Missing optional tools are skipped as noted; required tools must be installed separately. Earlier failures can prevent later checks from running.

### Repository-wide (`base`: every Git work tree)

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `secrets` | Fast | gitleaks; skip if missing | Detects credentials in staged changes, or the working tree including untracked files with `-All`/`-Full`, to prevent secret exposure. |
| `typos` | Fast | typos; skip if missing | Checks changed files, or the wider tree with `-All`/`-Full`, for spelling mistakes in code and text. |
| `vuln` | Full | osv-scanner v2+; skip if missing/older | Scans package sources recursively for known dependency vulnerabilities; no package sources means skip. |
| `orphan projects` | Advisory (`-All`/full) | None | Finds C# projects absent from solution/project references so an omitted build target is visible. |
| `shellcheck` | Advisory (fast/full) | shellcheck; skip if missing | Checks `.sh`/`.bash` scripts for shell mistakes that can break automation. |
| `actionlint` | Advisory (fast/full) | actionlint; skip if missing | Checks GitHub Actions workflow syntax and expressions to catch invalid CI jobs. |
| `hadolint` | Advisory (fast/full) | hadolint; skip if missing | Checks Dockerfiles for build and container best-practice problems. |
| `yamllint` | Advisory (fast/full) | yamllint; skip if missing | Checks YAML syntax and formatting to catch malformed configuration. |
| `editorconfig` | Advisory (fast/full) | editorconfig-checker; skip if missing | Checks matching files against a root `.editorconfig` to expose inconsistent whitespace and encoding. |
| `<n> dependency update(s) available` | Advisory (after passing full run) | Go, npm, golangci-lint, Cargo as available; network | Reports newer direct Go/npm dependencies and Go/golangci-lint/Rust toolchains so maintenance work is visible. |

Repository linters inspect changed files, or tracked files with `-All`/`-Full`. Secret scanning excludes ignored files, nested repositories, and binary media. Without a project gitleaks config, [qgate's rules](gate/qgate.gitleaks.toml) disable `generic-api-key`, `curl-auth-header`, and `curl-auth-user`; provider-specific rules remain enabled. Typos honors project configuration such as `_typos.toml` alongside gate defaults.

The runner also validates requested stacks/revisions and tool pins, rejects an unexpected zero-check run, and fails a Git hook if the staged tree changes during its execution. The update advisory is bounded to 30 seconds; `QGATE_NO_ADVISORY=1` disables its summary queries. Detailed `qgate outdated` labels are `go`, `npm`, and `tool`.

### Docs / Markdown (part of `base`)

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `markdownlint` | Advisory (fast/full) | markdownlint-cli2; skip if missing | Checks changed Markdown, or tracked Markdown with `-All`/`-Full`, for structural and formatting problems that hurt readability. Skips paths marked `linguist-vendored`/`linguist-generated` in `.gitattributes` (every advisory linter does), paths in `.markdownlintignore`, and the `ignores` of `.markdownlint-cli2.*`. |

### Go (`go.mod`)

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `gofmt` | Fast | Go (`gofmt`) | Rejects unformatted non-ignored Go files to keep source formatting consistent. |
| `go build` | Fast | Go | Compiles all module packages into temporary output to catch build errors. |
| `go vet` | Fast | Go | Finds suspicious constructs that compile but are likely incorrect. |
| `golangci-lint config verify` | Fast | golangci-lint | Validates the linter config schema to prevent local/CI disagreement; skips absent config or an older tool without this command. |
| `golangci-lint` | Fast | golangci-lint | Runs configured Go linters to catch defects; missing tool warns/skips in fast and fails in full. |
| `go test` | Fast/full | Go | Runs short cacheable tests in fast, and uncached shuffled tests in full, to catch behavioral regressions. |
| `go vet GOOS=<os>` | Full, opt-in | Go | Vets configured alternate operating-system targets to expose platform-specific defects. |
| `golangci-lint GOOS=<os>` | Full, opt-in | golangci-lint | Lints configured alternate operating-system targets so conditional source is checked. |
| `go test -race` | Full | Go + gcc/cgo | Detects data races; skips with a warning when gcc is missing or `CGO_ENABLED=0`. |
| `govulncheck` | Full | govulncheck; skip if missing | Finds known vulnerabilities reachable through Go dependencies rather than merely available updates. |
| `slow tests` | Advisory (full) | Go test output | Flags packages approaching the test timeout so slower CI/race runs are less surprising. |
| `CI parity` | Advisory (full) | None | Compares workflow Go variants with local coverage to expose untested GOOS/GOARCH/build tags. |
| `golangci floor` | Advisory (full) | None | Compares project lint configuration with the supplied template to reveal omitted checks. |
| `goleak` | Advisory (full) | Go package listing | Flags packages starting goroutines without leak-checking tests to reveal missing coverage. |
| `purity` | Advisory (full, opt-in) | Go + bundled checker; golangci-lint for API bans | Examines deterministic packages for nondeterministic APIs and constructs that can cause divergent results. |
| `property tests` | Advisory (full, opt-in) | None | Flags deterministic packages without property/fuzz tests to identify missing invariant coverage. |
| `flaky tests` | Advisory (full, opt-in); blocking with `fail: true` | Go; gcc for race mode | Scans fragile test deadlines and reruns selected packages under constrained scheduling to expose timing failures. |
| `go fuzz` | Advisory (full) | Go | Exercises fuzz targets for 10 seconds each within a 60-second module budget to find unexpected inputs. |
| `deadcode` | Advisory (full) | deadcode; skip if missing/stale | Reports unreachable functions so unused implementation can be reviewed. |
| `gremlins` | Advisory (`-Mutate`) | gremlins; skip if missing/stale | Mutates Go code and reports surviving mutants to reveal weak assertions. |

Go-built linter/scanner binaries older than the module's Go language version are rejected for golangci-lint/govulncheck; advisory tools are skipped. These are toolchain errors, not source findings.

### Protobuf / Buf (`buf.yaml`)

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `buf lint` | Fast | buf; missing tool fails stack | Checks schema rules to keep protobuf definitions consistent. |
| `buf format` | Fast | buf | Rejects protobuf formatting drift to keep schemas readable. |
| `buf breaking` | Full | buf + Git | Checks compatibility against the merge-base with `origin/main`, falling back to `HEAD~1`; skips without a usable baseline containing proto files. |
| `buf generate drift` | Full | buf + configured generators + Git | Regenerates code and detects newly dirty/untracked output so committed generated files match schemas; skips without `buf.gen.yaml` or Git. |

### Godot / GDScript (`project.godot`)

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `gdformat` | Fast | gdtoolkit | Checks GDScript formatting so source stays consistent. |
| `gdlint` | Fast | gdtoolkit | Checks GDScript lint rules to catch suspicious code. |
| `res:// references` | Fast | None | Validates case-sensitive resource paths and UID references to catch missing assets before runtime. |
| `godot import` | Full | Godot | Runs headless import with a warm-up pass to detect import and script errors. |
| `godot test <filename>` | Full | Godot | Runs each `*_headless_test.gd` script to detect script/test failures. |
| `godot smoke` | Full | Godot | Starts the project headlessly for one iteration to catch startup errors. |

Formatting/linting targets changed `.gd` files unless `-All`/`-Full`; `.godot` and `addons` are excluded. If either gdtoolkit command is missing, both phases warn/skip in fast and fail in full. Full requires Godot: set `GODOT_BIN` if it is not discovered. Timeouts fail the relevant Godot phase.

### C / C++ (`CMakeLists.txt`)

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `format` | Fast | clang-format; skip if missing | Checks changed sources, or all with `-All`/`-Full`, against `.clang-format`; skips without that config. |
| `configure` | Full | CMake + build toolchain | Configures the project and requests a compile database to catch invalid build configuration. |
| `build` | Full | CMake + build toolchain | Builds Release output to catch compiler/linker errors. |
| `tidy` | Advisory (full) | clang-tidy; skip if missing | Checks project-owned translation units for bug, security, and performance patterns using a compile database. |
| `cppcheck` | Advisory (full) | cppcheck; skip if missing | Checks project-owned code for warning, performance, and portability issues using a compile database. |

Full requires CMake. Analysis skips without a compile database; Ninja + clang-cl can generate a fallback database when the primary generator supplies none. Tidy/cppcheck findings are advisory, but unexplained tool failures can fail their phases. Nested CMake projects are checked through their parent tree.

### Web: JavaScript / TypeScript / Vue

Detected by `package.json` plus `vite.config.*`, `next.config.*`, `webpack.config.*`, or `rollup.config.*`. Missing `node_modules/.bin` fails the stack: install project dependencies first.

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `stylelint` | Fast | Local Stylelint | Checks Vue/CSS/SCSS when a Stylelint config exists, rejecting warnings to catch stylesheet problems. |
| `eslint` | Fast | Local ESLint | Checks source when an ESLint config exists, rejecting warnings to catch JavaScript/TypeScript/Vue defects. |
| `knip` | Advisory (`-All`/full) | Local Knip; skip if missing/unconfigured | Reports unused files, dependencies, and exports to expose dead project code. |
| `type-check` | Fast | npm script or local vue-tsc/tsc | Runs `type-check`, otherwise checks `tsconfig.json` without emitting; missing compiler with a tsconfig fails. |
| `build` | Full and default; skipped by `-Fast` alone | npm + project bundler | Runs `build-only` or `build` when declared to catch bundling failures. |
| `test` | Full | npm + project test runner | Runs the declared test script with `CI=1`, a 600-second timeout, and child-process leak detection to catch failed or hanging tests. |
| `npm audit` | Full | npm | Rejects high/critical dependency vulnerabilities; skips without `package-lock.json` or `npm-shrinkwrap.json`. |

When `tailwindcss` is present, `wire` adds `scss/at-rule-no-unknown` `ignoreAtRules` for Tailwind directives to the Stylelint config it creates; existing configs are preserved.

Configured Stylelint/ESLint phases require their local binaries; they are not optional missing-tool skips. No type-check script/tsconfig or build/test script means that phase does not run.

### Rust (`Cargo.toml` with `[package]`)

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `cargo fmt` | Fast | Cargo + rustfmt | Rejects formatting differences to keep Rust source consistent. |
| `cargo clippy` | Fast | Cargo + Clippy | Lints all targets with warnings treated as errors to catch likely defects. |
| `cargo test` | Fast | Cargo | Runs tests to catch behavioral regressions. |

Missing Cargo fails the stack; missing required Cargo components fail their commands.

### .NET / C# (`*.csproj`)

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `refs` | Fast | .NET SDK / MSBuild | Evaluates target frameworks and references to establish what can be built. |
| `format` | Fast | dotnet format whitespace | Verifies whitespace, scoped to changed C# files in fast/baseline runs, to enforce project formatting. |
| `<project>: <n> code-style violation(s)` | Advisory (full) | dotnet format style | Checks IDE style rules when `.editorconfig` is found so project conventions remain visible. |
| `build` | Fast/full | .NET SDK + NuGet analyzers | Compiles the project; full forces rebuilding and injects analyzers to expose compiler and code-quality defects. |
| `bepinex` | Advisory (full) | None | Checks plugin GUID/version metadata in BepInEx projects to catch malformed plugin identities. |
| `harmony` | Full | .NET SDK + bundled metadata checker | Resolves Harmony targets against built assemblies and references to catch patches that compile but cannot bind at runtime. |
| `inspectcode <project>` (pass only); `<project>: <n> InspectCode finding(s)` (findings) | Advisory (full, opt-in) | JetBrains `jb`; skip if missing | Reports dead code and redundancies beyond Roslyn diagnostics. |
| `test` | Full | dotnet test | Runs projects marked by `IsTestProject` or `Microsoft.NET.Test.Sdk` to catch test failures. |
| `test (dotnet run <project>)` | Advisory (full); blocking with `testRunner: "fail"` | dotnet run | Runs executable `.Test`/`.Tests` projects with a 600-second timeout to exercise custom test runners. |
| `vuln` | Full | dotnet list package + NuGet sources | Checks direct/transitive packages for known vulnerabilities; skips without packages and reports unknown when the scan cannot complete. |

Missing SDK warns/skips in fast and fails in full; projects needing a newer SDK are skipped. Missing game/SDK references skip build and later checks. Formatting that cannot load the project reports unknown. Full build uses SDK analyzers, Meziantou.Analyzer, and Unity analyzers for UnityEngine references; Sonar and BannedApi analyzers are opt-in and skipped when absent from the local NuGet cache (`BannedSymbols.txt` enables BannedApi). Warnings remain advisory unless project severity makes them errors. `.qgate-no-analyzers` beside the project disables injected packages; [analyzer settings](gate/qgate.analyzers.props) document suppressed rules, including CA5351. Analyzer injection failure retries without injection and warns.

### Custom / smoke / deploy (`qgate.json`)

| Printed check | Tier | External tool | What it checks and why |
| --- | --- | --- | --- |
| `<checks[].name>` (command) | Configured fast/full | PowerShell + declared command | Enforces project-specific commands by exit status, timeout, and leaked child processes; skips until trusted. |
| `<checks[].name>` (smoke) | Full | Declared Windows application | Checks log readiness/errors, staged screenshots and optional image baselines, and leaked processes to catch runtime failures; skips off Windows or without trust. |
| `deploy <filename>` | Full | None | Compares built/deployed SHA-256 hashes to detect stale binaries; skips when either artifact is absent. |

## When the gate is wrong

Report crashes, false positives, missed stacks, or unsatisfiable checks in a [GitHub issue](https://github.com/UberMorgott/quality-gate/issues/new). Include `qgate where` output, the exact command, the full error output, the file/check involved, and a minimal reproducer when possible. Redact credentials and private data. If details were truncated, include the underlying tool's full error too. Report the blocker rather than disabling the gate to claim success.
