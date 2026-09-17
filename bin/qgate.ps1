# Single entry point for the quality gate. Everything else is reached through it,
# so no call site anywhere ever needs an absolute path.
#
#   qgate                 run the gate on the current repo (fast level)
#   qgate -All -Full      any flag of gate/check.ps1, passed straight through
#   qgate wire            wire the current repo: agent hooks, configs, CI
#   qgate trust           allow this repo's own qgate.json checks to run here
#   qgate outdated        dependencies and toolchains with a newer release
#   qgate stop-hook       Claude Code `Stop` hook entry (reads stdin JSON)
#   qgate hold/release    background writer active: pause the Stop hook (#98)
#   qgate global on|off   opt-in: gate every repo via global core.hooksPath (#86)
#   qgate update          git pull in the install directory
#   qgate selftest        run the gate's own red-then-green self-test
#   qgate where           print the install directory and version
$ErrorActionPreference = 'Stop'
$home_ = Split-Path -Parent $PSScriptRoot
$rest = @($args)
$cmd = if ($rest.Count -gt 0 -and $rest[0] -notlike '-*') { $rest[0] } else { '' }
# Help flags are not gate flags: without this they reached check.ps1 and came back
# as "A parameter cannot be found that matches parameter name 'h'".
if ($rest.Count -gt 0 -and $rest[0] -in '-h', '-?', '--help', '/?') { $cmd = 'help' }
if ($cmd) { $rest = @($rest | Select-Object -Skip 1) }

$usage = @'
qgate -- one quality gate for every stack in the repository

  qgate                 run the gate on the current repo (fast level: changed files)
  qgate run             the same thing, spelled out (any gate flag works after it)
  qgate -All -Full      any flag of the gate, passed straight through
  qgate wire            wire the current repo (configs, agent hooks; -CI adds a workflow)
  qgate trust           print this repo's qgate.json "checks" and allow them to run here
                        (-Root <path> for another repo, -Remove to forget them)
  qgate outdated        dependencies and toolchains with a newer release
  qgate stop-hook       Claude Code `Stop` hook entry (reads stdin JSON)
  qgate hold            a background subagent is still writing: Stop hook off for 15 min
                        (-Minutes 1..120, `hold status`; `qgate release` ends it early)
                        commits stay gated -- this only affects the per-turn Stop hook
  qgate release         end the hold
  qgate global on       every git repo gets the gate (global core.hooksPath; off, status)
                        unwired repos without qgate.json: advisory; opt out: .qgate-off
  qgate update          git pull in the install directory
  qgate selftest        the gate's own red-then-green self-test
  qgate where           install path, commit and the tool versions in use

Gate flags: -All  -Fast  -Full  -Only <stack[,stack]>  -Quiet  -Why  -Baseline <rev>  -Mutate  -Fix  -Root <path>  -Sarif <file>  -Parallel
  -Quiet prints nothing on a green run and the whole report on a red one
       (what the generated pre-commit hook uses; CI wants the [PASS] lines).
       A [WARN] about the gate's own unreadable config is not silenced.
  -Fix  rewrites first (Go: gofmt -w, golangci-lint run --fix), then runs the normal gate.
       Explicit only: hooks and CI never pass it, the gate itself never rewrites.
  -Only takes base go web rust proto godot dotnet cpp custom: -Only go,web ("go,web" and `go web` are the same)
       base has no marker file -- it is every git work tree, and -Only base runs it alone
       python is detected but not checked, so a run that names it alone checks
       nothing and FAILS (-All flags it only when a real stack ran too)
A run that executed zero check phases is never green.
Exit codes: 0 pass, 1 fail, 2 from `stop-hook` blocks the agent's turn.
'@

function Invoke-Child([string]$script, [object[]]$argv) {
    # -File keeps $LASTEXITCODE meaningful; child scripts own their own output.
    & pwsh -NoProfile -File (Join-Path $home_ $script) @argv
    exit $LASTEXITCODE
}

switch ($cmd) {
    ''          { Invoke-Child 'gate\check.ps1'     $rest }
    'run'       { Invoke-Child 'gate\check.ps1'     $rest }
    'outdated'  { Invoke-Child 'gate\outdated.ps1'  $rest }
    'stop-hook' { Invoke-Child 'gate\stop-hook.ps1' $rest }
    'hold'      { Invoke-Child 'gate\hold.ps1'      $rest }
    # `release` is the same script: two verbs read better at a call site than `hold off`,
    # and an agent that has to remember one spelling remembers the wrong one.
    'release'   { Invoke-Child 'gate\hold.ps1'      (@('off') + $rest) }
    'wire'      { Invoke-Child 'install.ps1'        $rest }
    'trust'     { Invoke-Child 'gate\trust.ps1'     $rest }
    'selftest'  { Invoke-Child 'selftest.ps1'       $rest }
    'global'    { Invoke-Child 'gate\global.ps1'    $rest }
    'update' {
        # Same inherited-git-environment trap detect.ps1 clears for every other entry
        # point, and this branch is the one that does not dot-source it. Under a hook's
        # GIT_DIR, `-C $home_` names the directory but the variable names the
        # repository, so this would fast-forward the repository being COMMITTED.
        $env:GIT_DIR = $null
        $env:GIT_WORK_TREE = $null
        # #90: one install serves every repo, and agents update it at the same moment.
        # Measured: 8 parallel pulls failed 39/40 (FETCH_HEAD, ref and object writes collide),
        # so the pull is serialized on an exclusive handle in the install's git dir.
        $lockPath = Join-Path (git -C $home_ rev-parse --absolute-git-dir) 'qgate-update.lock'
        $lock = $null; $waited = $false; $deadline = (Get-Date).AddMinutes(5)
        while (-not $lock) {
            try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
            catch [IO.IOException] {
                if ((Get-Date) -gt $deadline) { Write-Output "qgate update: another update still holds $lockPath after 5 min"; exit 1 }
                if (-not $waited) { Write-Output 'qgate update: another update is running, waiting for it...'; $waited = $true }
                Start-Sleep -Milliseconds 250
            }
        }
        try { git -C $home_ pull --ff-only } finally { $lock.Dispose() }
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Output "quality-gate $(git -C $home_ rev-parse --short HEAD) at $home_"
        exit 0
    }
    'help' { Write-Output $usage; exit 0 }
    'where' {
        # Which gate actually ran, and with which tools. A second checkout earlier
        # on PATH silently answering for every repo on the machine is a real thing
        # that happened; so is a linter whose patch version differs from CI's.
        # Get-GodotBin: GODOT_BIN set in one shell is invisible to an editor-launched
        # agent hook, and that is exactly the failure this command has to explain.
        . (Join-Path $home_ 'gate\detect.ps1')
        Write-Output "install   $home_  $(git -C $home_ rev-parse --short HEAD 2>$null)"
        Write-Output "resolved  $((Get-Command qgate -ErrorAction SilentlyContinue).Source)"
        foreach ($t in 'go', 'golangci-lint', 'govulncheck', 'node', 'npm', 'cargo', 'dotnet', 'cmake', 'clang-format', 'clang-tidy', 'cppcheck', 'gitleaks', 'typos', 'osv-scanner', 'lefthook', 'buf', 'gdformat', 'gdlint') {
            $exe = Get-Command $t -ErrorAction SilentlyContinue
            # An absent tool is reported, not skipped: "what does the gate think it
            # has right now" is the whole question this command answers.
            if (-not $exe) { Write-Output "  $t -- not on PATH"; continue }
            $v = switch ($t) {
                'go' { (& go version) }
                'golangci-lint' { (& golangci-lint --version) }
                'node' { "node $(& node --version)" }
                'npm' { "npm $(& npm --version)" }
                'cargo' { (& cargo --version) }
                # The SDK list, not `--version`: the x86 host answers the latter and
                # can still build nothing at all.
                'dotnet' { "dotnet SDKs: $((@(& dotnet --list-sdks 2>$null | ForEach-Object { ($_ -split ' ')[0] }) -join ', '))" }
                # Prints a bare version number, which alone in the list reads as nothing.
                'lefthook' { "lefthook $(& lefthook version)" }
                # Prints a multi-line report; the scanner's own version is the line
                # that matters, and it was the only tool here showing no version.
                # The Go it was BUILT with matters just as much: a binary older than
                # the module's go directive fails with fifteen lines blaming the
                # user's own files, and this is the command that has to make that
                # visible. NOT from its own `Go:` line -- that one reports the
                # toolchain active in the current directory, so the same binary reads
                # go1.26.2 here and go1.27.1 inside a module that pulls a newer one.
                'govulncheck' {
                    $gv = (& govulncheck -version 2>&1)
                    "govulncheck $(($gv -match 'govulncheck@') -replace '.*govulncheck@', '') built with go$(Get-GoBuiltWith 'govulncheck')"
                }
                'buf' { "buf $(& buf --version)" }
                # Both already print their own name, and both print more than one line.
                'cmake' { (& cmake --version) }
                'clang-format' { (& clang-format --version) }
                # clang-tidy leads with `LLVM (http://llvm.org/):` and puts the number on
                # the line after it, so the first line alone would say nothing at all.
                'clang-tidy' { "clang-tidy $(((& clang-tidy --version) -match 'LLVM version') -replace '.*LLVM version ', '')" }
                'cppcheck' { (& cppcheck --version) }
                # The three base-stack tools. gitleaks prints a bare string and an
                # official build prints `version is set by build process` for it, so
                # the name has to come from here or the line reads as nothing.
                # osv-scanner's major version is what decides whether the vuln phase
                # runs at all -- v1 has no `scan source` -- and it prints three lines.
                'gitleaks' { "gitleaks $(& gitleaks version)" }
                'typos' { (& typos --version) }
                'osv-scanner' { (& osv-scanner --version) }
                # gdformat/gdlint already print their own name.
                'gdformat' { (& gdformat --version) }
                'gdlint' { (& gdlint --version) }
                default { $t }
            }
            Write-Output "  $(($v | Select-Object -First 1))"
        }
        $godot = Get-GodotBin
        if ($godot) {
            Write-Output "  godot $(((& $godot --version 2>$null) | Select-Object -First 1))  $godot"
        } else {
            Write-Output '  godot -- not found; set GODOT_BIN to the Godot executable'
        }
        exit 0
    }
    default {
        [Console]::Error.WriteLine("qgate: unknown command '$cmd'. Try: run, wire, trust, global, outdated, stop-hook, hold, release, update, selftest, where")
        exit 64
    }
}
