# Self-test: proves the gate FAILS on a real violation and PASSES once it is
# fixed. A gate nobody has seen fail is not known to work.
#
#   pwsh -NoProfile -File selftest.ps1
#
# Adding a check: assert the REASON, not only the outcome. Five defects in a row
# here were the gate doing something defensible and printing a reason that was not
# the reason -- right exit code, right stacks, wrong explanation -- and every one of
# them satisfied a suite that asserted only pass/fail. So a negative check states
# three things: the outcome, that the reason which applied was printed (-match), and
# that the reason which did NOT apply is absent (-notmatch). The third is the cheap
# one and the one that was missing. Assert absence too: "narrowed to the right
# stack" is proved by the other stacks NOT running. See PLAYBOOK.md 0.1.
#
#   pwsh -NoProfile -File selftest.ps1 -Only go,base
#
# -Only runs just the named sections, for iterating on one stack (#81). The full run
# with no -Only stays the push gate.
#
# Sections run as parallel child processes (#84): the run is waiting on processes, not
# CPU, so one section at a time left the cores idle. -Sequential runs everything in this
# process, as before. -SectionTimeoutSec bounds each child.
#
# The longest sections are split into parts (go2, dotnet2, dotnet3) so they run as parallel
# jobs too; naming a section runs its parts. -Exact (what each job gets) runs only the
# names given.
param([string[]]$Only, [switch]$Sequential, [switch]$Exact, [int]$SectionTimeoutSec = 1500)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gate\detect.ps1')

# No registry in the loop: every fixture is a new path, so the full run's update advisory
# never answered from its cache and asked the network on each green -Full run (#84). The
# advisory's own checks (section core) put it back for their runs.
$env:QGATE_NO_ADVISORY = '1'

$sections = 'detect', 'go', 'go2', 'core', 'wiring', 'rust', 'dotnet', 'dotnet2', 'dotnet3', 'proto', 'godot', 'hooks', 'custom', 'cpp', 'base', 'web', 'bootstrap'
$parts = @{ go = @('go2'); dotnet = @('dotnet2', 'dotnet3') }
# `pwsh -File` hands "go,base" over as one string.
$Only = @($Only -split ',' | ForEach-Object Trim | Where-Object { $_ })
$bad = @($Only | Where-Object { $_ -notin $sections })
if ($bad) { Write-Output "unknown section(s): $($bad -join ', '); valid: $($sections -join ', ')"; exit 2 }
if (-not $Exact) { $Only = @($Only | ForEach-Object { $_; $parts[$_] } | Where-Object { $_ } | Select-Object -Unique) }

if (-not $Sequential -and $Only.Count -ne 1) {
    $run = @(if ($Only) { $sections | Where-Object { $_ -in $Only } } else { $sections })
    # base runs the cpp section itself (it reuses that fixture); a separate cpp job would
    # count those checks twice.
    if ('base' -in $run) { $run = @($run | Where-Object { $_ -ne 'cpp' }) }
    $ptmp = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-selftest-par-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $ptmp | Out-Null
    $self = $PSCommandPath
    $jobs = foreach ($s in $run) {
        $dir = Join-Path $ptmp $s
        New-Item -ItemType Directory -Path $dir | Out-Null
        [pscustomobject]@{ Name = $s; Dir = $dir; Out = Join-Path $ptmp "$s.out"; Proc = $null; Watch = $null; TimedOut = $false }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $throttle = [Math]::Max(2, [Environment]::ProcessorCount)
    while ($jobs | Where-Object { -not $_.Proc -or -not $_.Proc.HasExited }) {
        $jobs | Where-Object { $_.Proc -and $_.Proc.HasExited } | ForEach-Object { $_.Watch.Stop() }
        foreach ($j in @($jobs | Where-Object { $_.Proc -and -not $_.Proc.HasExited -and $_.Watch.Elapsed.TotalSeconds -gt $SectionTimeoutSec })) {
            $j.TimedOut = $true
            try { $j.Proc.Kill($true) } catch { Write-Verbose "kill $($j.Name): $_" }
        }
        $busy = @($jobs | Where-Object { $_.Proc -and -not $_.Proc.HasExited }).Count
        foreach ($j in @($jobs | Where-Object { -not $_.Proc } | Select-Object -First ($throttle - $busy))) {
            # Own TEMP per child: the gate keys temp files and tools keep lock files there
            # (golangci-lint's parallel-runner lock), which concurrent sections must not share.
            $cmd = "`$env:TMP = `$env:TEMP = '$($j.Dir)'; & '$self' -Only $($j.Name) -Sequential -Exact *> '$($j.Out)'; exit `$LASTEXITCODE"
            $j.Proc = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', $cmd -PassThru -WindowStyle Hidden
            $j.Watch = [Diagnostics.Stopwatch]::StartNew()
        }
        Start-Sleep -Milliseconds 500
    }
    $jobs | ForEach-Object { $_.Watch.Stop() }
    $total = 0; $fails = 0
    foreach ($j in $jobs) {
        $text = if (Test-Path $j.Out) { Get-Content $j.Out -Raw } else { '' }
        $secs = [int]$j.Watch.Elapsed.TotalSeconds
        Write-Output "===== section $($j.Name) ($secs s, exit $($j.Proc.ExitCode))"
        Write-Output $text.TrimEnd()
        # Every job must end in the summary line; a crash, hang or kill without one is a
        # failed section, never a silently missing one.
        if ($text -match '(?m)^all checks passed \((\d+)/\d+\)') { $total += [int]$Matches[1] }
        elseif ($text -match '(?m)^(\d+) of (\d+) check\(s\) failed') { $total += [int]$Matches[2]; $fails += [int]$Matches[1] }
        # Every check of the section skipped for a missing tool: nothing counted, as in a sequential run.
        elseif ($text -match '(?m)^no checks ran') { Write-Verbose "section $($j.Name): no checks ran" }
        else {
            $why = if ($j.TimedOut) { "timed out after $SectionTimeoutSec s" } else { "exited $($j.Proc.ExitCode) without a summary" }
            Write-Output "[FAIL] section $($j.Name) $why"; $total++; $fails++
        }
    }
    Remove-Item $ptmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "`nwall time $([int]$sw.Elapsed.TotalSeconds) s, $($jobs.Count) section job(s)"
    if ($total -eq 0) { Write-Output "`nno checks ran"; exit 1 }
    if ($fails) { Write-Output "`n$fails of $total check(s) failed"; exit 1 }
    Write-Output "`nall checks passed ($total/$total)"
    exit 0
}
# base reuses the cpp fixture section 36 builds.
$want = @($Only) + @(if ('base' -in $Only) { 'cpp' })
function Want([string]$Name) { (-not $Only) -or ($Name -in $want) }
# Paths several sections share, so a filtered run does not depend on the section
# that first named them.
$installer = Join-Path $PSScriptRoot 'install.ps1'
$gate = Join-Path $PSScriptRoot 'gate\check.ps1'

# Unique per run: a fixed directory made two concurrent self-tests delete each
# other's fixtures mid-check.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "quality-gate-selftest-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmp | Out-Null

$script:Fails = 0
# Counted, because the last line claiming "all checks passed" is the only thing
# anybody reads, and a suite that silently stopped running half of them would say
# exactly the same words. The number also makes the one quoted in README verifiable
# output rather than prose. It moves with the machine: checks whose tool is absent
# report [skip] and are never counted.
$script:Total = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:Total++
    if ($Ok) { Write-Output "[ok]   $Name" }
    else { Write-Output "[FAIL] $Name $Detail"; $script:Fails++ }
}
function Set-GoFile([string]$Path, [string]$Text) {
    # LF only: gofmt reports a CRLF file as unformatted, which would fail the
    # wrong phase and hide the violation we are testing for.
    [IO.File]::WriteAllText($Path, (($Text -replace "`r`n", "`n").TrimEnd() + "`n"))
}
# #82: a vulnerability scanner stand-in. Prints $Json when its arguments contain $JsonArg
# (exit 0), otherwise $Text with exit $Code; `--version` answers as osv-scanner v2.
function New-VulnShim([string]$Dir, [string]$Name, [string]$JsonArg, [string]$Json, [string]$Text, [int]$Code) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $jf = Join-Path $Dir "$Name.json"
    [IO.File]::WriteAllText($jf, $Json)
    if ($IsWindows) {
        [IO.File]::WriteAllText((Join-Path $Dir "$Name.cmd"), "@if `"%1`"==`"--version`" (echo osv-scanner version: 2.5.1& exit /b 0)`r`n@echo %* | findstr /c:`"$JsonArg`" >nul && (type `"$jf`" & exit /b 0)`r`n@echo $Text`r`n@exit /b $Code`r`n")
    } else {
        $p = Join-Path $Dir $Name
        [IO.File]::WriteAllText($p, "#!/bin/sh`n[ `"`$1`" = --version ] && { echo 'osv-scanner version: 2.5.1'; exit 0; }`ncase `"`$*`" in *'$JsonArg'*) cat '$jf'; exit 0;; esac`necho '$Text'`nexit $Code`n")
        chmod +x $p
    }
}
function Invoke-Gate([string]$Root) {
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $Root -All 2>&1 | Out-String)
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

if (Want 'detect') {
# 1. Detection by file presence.
$stacks = @(Get-Stacks (Join-Path $PSScriptRoot 'testdata'))
# ...except the one whose marker is the repository itself. testdata/ is inside this
# work tree, so base is there beside every stack a marker file created. Section 37
# asserts the rest of it: alone in a bare repo, and absent outside a work tree.
Check 'detects base stack with no marker file' `
    ([bool]($stacks | Where-Object { $_.Stack -eq 'base' -and $_.Marker -eq 'git work tree' -and $_.Implemented }))
Check 'detects go stack'   ([bool]($stacks | Where-Object { $_.Stack -eq 'go' -and $_.Implemented }))
Check 'detects web stack'  ([bool]($stacks | Where-Object { $_.Stack -eq 'web' -and $_.Implemented }))
Check 'detects rust stack'  ([bool]($stacks | Where-Object { $_.Stack -eq 'rust' -and $_.Implemented }))
Check 'detects proto stack' ([bool]($stacks | Where-Object { $_.Stack -eq 'proto' -and $_.Implemented }))
Check 'detects godot stack' ([bool]($stacks | Where-Object { $_.Stack -eq 'godot' -and $_.Implemented }))
# The one marker that is a PATTERN: a csproj is named after its project, and one .NET
# repo carries several of them. The marker recorded has to be the file, not the glob.
Check 'detects dotnet stack by its csproj name' `
    ([bool]($stacks | Where-Object { $_.Stack -eq 'dotnet' -and $_.Marker -eq 'Fixture.csproj' -and $_.Implemented }))
Check 'detects cpp stack' ([bool]($stacks | Where-Object { $_.Stack -eq 'cpp' -and $_.Marker -eq 'CMakeLists.txt' -and $_.Implemented }))
Check 'detects python stack as not implemented' ([bool]($stacks | Where-Object { $_.Stack -eq 'python' -and -not $_.Implemented }))
# A stack with no marker file does not exist at all. testdata/ now holds a python
# fixture (check 28 needs one), so this has to be asked of a tree that has no python
# marker, or it would only be proving that Copy-Item works.
Check 'no phantom python stack where there is no marker' `
    (-not (@(Get-Stacks (Join-Path $PSScriptRoot 'testdata\go-fixture')) | Where-Object { $_.Stack -eq 'python' }))
# What the repo ignores is not part of the repo. Claude Code checks agent worktrees
# out under .claude/worktrees/<agent>/, and that nested go.mod -- an older commit of
# the same repo -- was detected as a second Go stack, so `qgate outdated` reported
# dependencies as behind that were only stale inside the worktree. Both halves are
# asserted: the ignored module is gone AND the root one is still found, because
# "detects nothing at all" would satisfy the first half on its own.
$ign = Join-Path $tmp 'ignored'
New-Item -ItemType Directory -Path (Join-Path $ign '.claude\worktrees\agent-x') -Force | Out-Null
git -C $ign init -q 2>$null
Set-Content (Join-Path $ign '.gitignore') '.claude/'
Set-Content (Join-Path $ign 'go.mod') 'module example.com/root'
Set-Content (Join-Path $ign '.claude\worktrees\agent-x\go.mod') 'module example.com/nested'
$ignStacks = @(Get-Stacks $ign | Where-Object { $_.Stack -eq 'go' })
Check 'a gitignored nested module is not a stack' `
    (($ignStacks.Count -eq 1) -and ($ignStacks[0].Rel -eq '')) `
    (($ignStacks | ForEach-Object { "go '$($_.Rel)'" }) -join ' | ')

# Not walking in is only half of it: the PHASES must not walk in either. gofmt is the
# one Go tool with no notion of modules or ignore rules -- `.` is the whole subtree --
# so a CRLF checkout under .claude/worktrees/<agent>/ failed the ROOT repo's gate, and
# its pre-commit hook, over files that are not in its index. Both directions are
# asserted, because "ignore the ignored file" is also what gofmt switched off would do.
$gign = Join-Path $tmp 'gofmt-ignored'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $gign -Recurse
Set-Content (Join-Path $gign '.gitignore') '.claude/'
git -C $gign init -q 2>$null
git -C $gign add -A 2>$null
git -C $gign -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
New-Item -ItemType Directory -Path (Join-Path $gign '.claude\worktrees\agent-x') -Force | Out-Null
Set-Content (Join-Path $gign '.claude\worktrees\agent-x\go.mod') 'module example.com/nested'
[IO.File]::WriteAllText((Join-Path $gign '.claude\worktrees\agent-x\bad.go'), "package nested`r`n`r`nfunc  Bad()  {}`r`n")
$r = Invoke-Gate $gign
Check 'an unformatted file in a gitignored worktree does not fail the gate' `
    (($r.Code -eq 0) -and ($r.Out -notmatch 'bad\.go')) $r.Out
# '{0:N1}' formats with the CURRENT culture: on a ru-RU machine every phase printed
# `(0,0s)`, so the timings this report exists to show meant something different per
# machine and parsed as nothing. Both halves -- a dot present, no comma anywhere.
Check 'a phase time prints with a dot in any locale' `
    (($r.Out -match '\(\d+\.\ds\)') -and ($r.Out -notmatch '\(\d+,\ds\)')) $r.Out
[IO.File]::WriteAllText((Join-Path $gign 'ugly.go'), "package main`n`nfunc  Ugly()  {}`n")
$r = Invoke-Gate $gign
Check 'gofmt still fails on a real unformatted file' `
    (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] gofmt') -and ($r.Out -match 'ugly\.go') -and ($r.Out -notmatch 'bad\.go')) $r.Out

# #78: a directory with its own .git is another project, even untracked and unignored --
# git never descends into one, and neither may detection or the whole-tree base phases.
# The nested repo is red on every axis (CRLF Go, a csproj, typos, a secret); the outer
# repo stays green, and the same defects placed in the outer repo still fail.
$nr = Join-Path $tmp 'nested-repo'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $nr -Recurse
Set-Content (Join-Path $nr '.gitignore') 'ignored/'
git -C $nr init -q 2>$null
git -C $nr add -A 2>$null
git -C $nr -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
$nrIn = Join-Path $nr 'deep\inner'
New-Item -ItemType Directory -Path (Join-Path $nrIn 'App'), (Join-Path $nr 'ignored') -Force | Out-Null
git -C $nrIn init -q 2>$null
Set-Content (Join-Path $nrIn 'go.mod') 'module example.com/nested'
[IO.File]::WriteAllText((Join-Path $nrIn 'bad.go'), "package nested`r`n`r`nfunc  Bad()  {}`r`n")
Set-Content (Join-Path $nrIn 'App\App.csproj') '<Project Sdk="Microsoft.NET.Sdk" />'
Set-Content (Join-Path $nrIn 'notes.txt') 'teh recieve'
Set-Content (Join-Path $nrIn 'k.txt') ('token = "ghp_' + 'aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5"')
Set-Content (Join-Path $nr 'ignored\go.mod') 'module example.com/ign'
[IO.File]::WriteAllText((Join-Path $nr 'ignored\bad.go'), "package ign`r`n`r`nfunc  Bad()  {}`r`n")
$nrStacks = @(Get-Stacks $nr | Where-Object { $_.Stack -ne 'base' })
Check 'a nested repository and a gitignored dir are not stacks' `
    ((($nrStacks | ForEach-Object { "$($_.Stack):$($_.Rel)" }) -join ',') -eq 'go:') `
    (($nrStacks | ForEach-Object { "$($_.Stack):$($_.Rel)" }) -join ',')
Check 'the nested repository is named' ((@(Get-NestedRepos $nr) -join ',') -eq 'deep/inner')
$r = Invoke-Gate $nr
Check 'a red nested repository does not fail the outer gate' `
    (($r.Code -eq 0) -and ($r.Out -notmatch 'deep[\\/]inner|bad\.go')) $r.Out
[IO.File]::WriteAllText((Join-Path $nr 'ugly.go'), "package main`n`nfunc  Ugly()  {}`n")
$r = Invoke-Gate $nr
Check 'gofmt still fails in the outer repo beside a nested one' `
    (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] gofmt') -and ($r.Out -match 'ugly\.go') -and ($r.Out -notmatch 'bad\.go')) $r.Out
Remove-Item (Join-Path $nr 'ugly.go')
if (Get-Command typos -ErrorAction SilentlyContinue) {
    Set-Content (Join-Path $nr 'own.txt') 'teh'
    $r = Invoke-Gate $nr
    Check 'typos still fails in the outer repo beside a nested one' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] typos') -and ($r.Out -match 'own\.txt') -and ($r.Out -notmatch 'recieve')) $r.Out
    Remove-Item (Join-Path $nr 'own.txt')
}
if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
    Copy-Item (Join-Path $nrIn 'k.txt') (Join-Path $nr 'k.txt')
    $r = Invoke-Gate $nr
    Check 'gitleaks still fails in the outer repo beside a nested one' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] secrets') -and ($r.Out -match '(?m)^\s*k\.txt:1') -and ($r.Out -notmatch 'deep/inner/k\.txt')) $r.Out
}

# The Godot runner had the identical hole: it collects every *.gd with
# Get-ChildItem -Recurse and excluded only .godot/ and addons/, so the same nested
# checkout reddened a godot repo's root gate. The question is asked per DIRECTORY and
# cached there rather than per file -- this list is every script in the project, while
# gofmt only ever names the handful it wants reformatted.
if ((Get-Command gdformat -ErrorAction SilentlyContinue) -and (Get-Command gdlint -ErrorAction SilentlyContinue)) {
    $gdIgn = Join-Path $tmp 'godot-ignored'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\godot-fixture') $gdIgn -Recurse
    Set-Content (Join-Path $gdIgn '.gitignore') '.claude/'
    git -C $gdIgn init -q 2>$null
    git -C $gdIgn add -A 2>$null
    git -C $gdIgn -c user.email=selftest@local -c user.name=selftest commit -qm init *> $null
    $uglyGd = "extends Node`n`nfunc  _ready():`n        var x    =   1`n        print( x )`n"
    New-Item -ItemType Directory -Path (Join-Path $gdIgn '.claude\worktrees\agent-x') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $gdIgn '.claude\worktrees\agent-x\bad.gd'), $uglyGd)
    $r = Invoke-Gate $gdIgn
    Check 'a misformatted .gd in a gitignored worktree does not fail the gate' `
        (($r.Code -eq 0) -and ($r.Out -notmatch 'bad\.gd')) $r.Out
    [IO.File]::WriteAllText((Join-Path $gdIgn 'ugly.gd'), $uglyGd)
    $r = Invoke-Gate $gdIgn
    Check 'gdformat still fails on a misformatted .gd in the project' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] gdformat') -and ($r.Out -match 'ugly\.gd') -and ($r.Out -notmatch 'bad\.gd')) $r.Out
} else {
    Write-Output '[skip] gdformat/gdlint not on PATH -- the Godot ignore filter cannot run'
}

}

if (Want 'go') {
# 2. Clean Go fixture, no linter config -> passes, warns exactly once.
$go = Join-Path $tmp 'go'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $go -Recurse
$r = Invoke-Gate $go
Check 'clean go fixture passes without config' ($r.Code -eq 0) $r.Out
Check 'missing .golangci.yml warned once' (([regex]::Matches($r.Out, 'no \.golangci\.yml')).Count -eq 1) $r.Out
$script:noCfgOut = $r.Out

# 3. Same fixture with the template config -> still green, no warning.
Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $go
$r = Invoke-Gate $go
Check 'template .golangci.yml passes' ($r.Code -eq 0) $r.Out
Check 'no warning once config present' ($r.Out -notmatch 'WARN') $r.Out
$script:tplOut = $r.Out
# #52: the template must satisfy golangci-lint's own schema (embedded, offline), and so
# must its commented-out formatters block once a repo uncomments it. The negative half:
# a bare `rules:` (YAML null) is what the schema rejected before, so it must still fail.
if (Get-Command golangci-lint -ErrorAction SilentlyContinue) {
    $tplText = Get-Content (Join-Path $PSScriptRoot 'templates\.golangci.yml') -Raw
    $vOut = (& golangci-lint config verify -c (Join-Path $go '.golangci.yml') 2>&1 | Out-String)
    Check 'template .golangci.yml passes config verify' ($LASTEXITCODE -eq 0) $vOut
    $fi = $tplText.IndexOf('# formatters:'); $fj = $tplText.IndexOf("`n# OPT-IN", $fi)
    $fmtCfg = Join-Path $tmp 'golangci-formatters.yml'
    [IO.File]::WriteAllText($fmtCfg, $tplText.Substring(0, $fi) + ($tplText.Substring($fi, $fj - $fi) -replace '(?m)^# ?', '') + $tplText.Substring($fj))
    $vOut = (& golangci-lint config verify -c $fmtCfg 2>&1 | Out-String)
    Check 'uncommented gofumpt+gci formatters block passes config verify' (($fi -gt 0) -and ($LASTEXITCODE -eq 0) -and ((Get-Content $fmtCfg -Raw) -match '(?m)^formatters:')) $vOut
    $nullCfg = Join-Path $tmp 'golangci-null-rules.yml'
    [IO.File]::WriteAllText($nullCfg, ($tplText -replace '(?m)^    rules: \[\]', '    rules:'))
    $vOut = (& golangci-lint config verify -c $nullCfg 2>&1 | Out-String)
    Check 'a bare rules: still fails config verify' (($LASTEXITCODE -ne 0) -and ($vOut -match 'rules')) $vOut
    $global:LASTEXITCODE = 0
    # #83: the gate itself runs `config verify` (golangci-lint-action does): no config is not
    # a finding, the valid template passes it, a schema-invalid config fails before `run`.
    Check 'no config: config verify phase not reported' ($script:noCfgOut -notmatch 'config verify') $script:noCfgOut
    Check 'template config passes the config verify phase' ($script:tplOut -match '\[PASS\] golangci-lint config verify') $script:tplOut
    [IO.File]::WriteAllText((Join-Path $go '.golangci.yml'), $tplText + "`nbogus-key: 1`n")
    $r = Invoke-Gate $go
    Check 'schema-invalid .golangci.yml fails config verify' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] golangci-lint config verify') -and ($r.Out -match 'bogus-key')) $r.Out
    Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $go -Force
    # #43: a repo config below the template floor is named, a deliberate omission written
    # down in the config is not, and the template itself has no gap.
    $floor = Join-Path $tmp 'floor'
    New-Item -ItemType Directory -Path $floor | Out-Null
    [IO.File]::WriteAllText((Join-Path $floor '.golangci.yml'), "version: `"2`"`nlinters:`n  enable:`n    - errorlint`n    # gosec: off -- G115 is noise on fixed-point code`n")
    $fw = @(Get-GolangciFloorGaps $floor 'server' (Join-Path $PSScriptRoot 'templates\.golangci.yml')) -join "`n"
    Check 'a config below the golangci floor is warned with the missing names' `
        (($fw -match '^\[WARN\] golangci floor: server/\.golangci\.yml') -and ($fw -match 'linters: .*\bbodyclose\b') -and ($fw -match 'govet analyzers: .*\bnilness\b')) $fw
    Check 'a floor linter named in the config (with a reason) is not a gap' ($fw -notmatch '\bgosec\b') $fw
    Check 'the template config itself has no floor gap' (-not (Get-GolangciFloorGaps $go '' (Join-Path $PSScriptRoot 'templates\.golangci.yml')))
} else { Write-Output '[skip] golangci-lint not on PATH -- template schema checks cannot run' }

# #47: a tested package that starts a goroutine and never checks for leaks is named;
# the clean fixture (no goroutine) is not, and a goleak check in its tests clears it.
$leak = Join-Path $tmp 'goleak'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $leak -Recurse
Check 'no goleak warning on a package that starts no goroutine' (-not (Get-GoleakGaps $leak))
Set-GoFile (Join-Path $leak 'worker.go') "package main`n`n// Spawn starts a worker.`nfunc Spawn() {`n`tgo func() {}()`n}"
$lw = "$(Get-GoleakGaps $leak)"
Check 'a tested package starting goroutines without goleak is warned' ($lw -match '^\[WARN\] goleak: 1 package\(s\) .*: \./ ') $lw
Set-GoFile (Join-Path $leak 'leak_test.go') "package main`n`n// TestMain would call goleak.VerifyTestMain(m); a mention is what the scan reads."
Check 'a goleak check in the package tests clears the warning' (-not (Get-GoleakGaps $leak))

# #49: a Fuzz target that crashes within its budget is warned with the failing input,
# and the input go wrote into testdata/ is gone again (left there, every later plain
# `go test` would fail on it). A target that holds is run and warns nothing, and one
# past the budget is named, not silently dropped.
$fz = Join-Path $tmp 'fuzz'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $fz -Recurse
$fuzzSrc = "package main`n`nimport `"testing`"`n`nfunc FuzzAdd(f *testing.F) {`n`tf.Add(`"a`")`n`tf.Fuzz(func(t *testing.T, s string) {`n`t`tif len(s) > 1 && s[0] == 'z' {`n`t`t`tt.Fatal(`"crash`")`n`t`t}`n`t})`n}"
Set-GoFile (Join-Path $fz 'fuzz_test.go') $fuzzSrc
$fr = Invoke-GoFuzz $fz 5 60
$fw = $fr.Warn -join "`n"
Check 'a crashing fuzz target is warned with its failing input' `
    (($fr.Ran -eq 1) -and ($fw -match '\[WARN\] go fuzz: \S+ FuzzAdd failed -- advisory') -and ($fw -match 'go test fuzz v1')) $fw
Check 'the failing input go wrote is removed from the tree' (-not (Test-Path (Join-Path $fz 'testdata'))) $fw
Set-GoFile (Join-Path $fz 'fuzz_test.go') ($fuzzSrc -replace 'len\(s\) > 1', 'false')
$fr = Invoke-GoFuzz $fz 2 60
Check 'a fuzz target that holds runs and warns nothing' (($fr.Ran -eq 1) -and -not $fr.Warn) ($fr.Warn -join "`n")
$fr = Invoke-GoFuzz $fz 2 1
Check 'a fuzz target past the budget is named, not dropped' (($fr.Ran -eq 0) -and (($fr.Warn -join ' ') -match 'budget 1s spent -- not run: FuzzAdd')) ($fr.Warn -join "`n")

# #51: an unreachable function is warned; the clean fixture, a helper only its tests call,
# and a module with no main package and no tests (no program to walk) are not.
if ((Get-Command deadcode -ErrorAction SilentlyContinue) -and -not (Test-GoToolStale 'deadcode' ((go env GOVERSION) -replace '^go', '') 'x')) {
    $dc = Join-Path $tmp 'deadcode'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $dc -Recurse
    Check 'deadcode is silent on the clean fixture' (-not (Get-GoDeadcode $dc))
    Set-GoFile (Join-Path $dc 'helper.go') "package main`n`nfunc testOnly() int { return 1 }`n`nfunc orphan() {}"
    Set-GoFile (Join-Path $dc 'helper_test.go') "package main`n`nimport `"testing`"`n`nfunc TestHelper(t *testing.T) { _ = testOnly() }"
    $dw = (Get-GoDeadcode $dc) -join "`n"
    Check 'an unreachable function is warned by deadcode' (($dw -match '^\[WARN\] deadcode: 1 unreachable') -and ($dw -match 'unreachable func: orphan')) $dw
    Check 'a helper only tests call is not dead code' ($dw -notmatch 'testOnly') $dw
    Set-GoFile (Join-Path $dc 'main.go') "// Package lib is a library.`npackage lib`n`n// Add returns the sum of a and b.`nfunc Add(a, b int) int { return a + b }"
    Get-ChildItem $dc -Filter '*.go' | Where-Object Name -ne 'main.go' | Remove-Item
    Check 'a module with no main package is not a deadcode warning' (-not (Get-GoDeadcode $dc)) "$(Get-GoDeadcode $dc)"
} else { Write-Output '[skip] deadcode not on PATH or stale -- deadcode checks cannot run' }

# #46: purity profile, opt-in through qgate.json go.deterministic. No key is no check; a
# malformed key is named; a listed impure package is warned per construct; a listed pure
# package is not.
$pur = Join-Path $tmp 'purity'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $pur -Recurse
New-Item -ItemType Directory -Path (Join-Path $pur 'sim'), (Join-Path $pur 'fixed') | Out-Null
Set-GoFile (Join-Path $pur 'sim\sim.go') "package sim`n`nimport (`n`t`"math/rand`"`n`t`"time`"`n)`n`n// Step is impure.`nfunc Step(m map[string]int) float64 {`n`t_ = time.Now()`n`tfor k := range m {`n`t`t_ = k`n`t}`n`tgo func() {}()`n`treturn float64(rand.Int())`n}"
Set-GoFile (Join-Path $pur 'fixed\fixed.go') "package fixed`n`n// Add is pure.`nfunc Add(a, b int64) int64 {`n`tfor i := range []int{1} {`n`t`ta += int64(i)`n`t}`n`treturn a + b`n}"
Check 'no qgate.json go.deterministic key is no purity check' ($null -eq (Get-GoDeterministic $pur))
[IO.File]::WriteAllText((Join-Path $pur 'qgate.json'), '{"go": {"deterministic": "sim"}}')
Check 'a non-array go.deterministic is a named config error' ((Get-GoDeterministic $pur).Error -match 'must be an array')
[IO.File]::WriteAllText((Join-Path $pur 'qgate.json'), '{"go": {"deterministic": ["nosuch"]}}')
Check 'a go.deterministic directory that does not exist is a named config error' ((Get-GoDeterministic $pur).Error -match "'nosuch' is not a directory")
[IO.File]::WriteAllText((Join-Path $pur 'qgate.json'), '{"go": {"deterministic": ["sim", "fixed"]}}')
$det = Get-GoDeterministic $pur
Check 'go.deterministic lists both package dirs' ((-not $det.Error) -and $det.Dirs.Count -eq 2) "$($det.Error)"
$pw = (Get-GoPurity $pur @($det.Dirs[0])) -join "`n"
Check 'an impure deterministic package is warned: map range, go statement' `
    (($pw -match '^\[WARN\] purity: ') -and ($pw -match 'sim/sim\.go:\d+:\d+: range over map') -and ($pw -match 'go statement')) $pw
if (Get-Command golangci-lint -ErrorAction SilentlyContinue) {
    Check 'an impure deterministic package is warned: time.Now, float64, math/rand' `
        (($pw -match 'time\.Now') -and ($pw -match 'float64') -and ($pw -match "import 'math/rand'")) $pw
}
Check 'a pure deterministic package is clean (range over a slice is fine)' (-not (Get-GoPurity $pur @($det.Dirs[1]))) "$(Get-GoPurity $pur @($det.Dirs[1]))"

# #48: a listed deterministic package with no property or fuzz test is warned; a rapid
# property test or a Fuzz target clears it; a plain unit test does not.
Set-GoFile (Join-Path $pur 'fixed\fixed_test.go') "package fixed`n`nimport `"testing`"`n`nfunc TestAdd(t *testing.T) { _ = Add(1, 2) }"
$gw = "$(Get-GoPropertyGaps $pur $det.Dirs)"
Check 'deterministic packages without a property or fuzz test are warned' ($gw -match '^\[WARN\] property tests: 2 deterministic package\(s\) .*: sim, fixed ') $gw
Set-GoFile (Join-Path $pur 'fixed\prop_test.go') "package fixed`n`n// rapid.Check(t, func(t *rapid.T) { ... }) is what the scan reads."
Set-GoFile (Join-Path $pur 'sim\sim_test.go') "package sim`n`nimport `"testing`"`n`nfunc FuzzStep(f *testing.F) { f.Fuzz(func(t *testing.T, n int) {}) }"
Check 'a rapid property test or a Fuzz target clears the warning' (-not (Get-GoPropertyGaps $pur $det.Dirs)) "$(Get-GoPropertyGaps $pur $det.Dirs)"
# #40: cross-GOOS vet/lint, opt-in through qgate.json go.lintGoos. No key and the host's own
# GOOS are no extra phase; a bad name is named; a vet defect in a file only the other GOOS
# compiles passes the host vet and fails the gate at -Full; the clean file passes cross vet.
$hostOs = go env GOOS
$otherOs = if ($hostOs -eq 'linux') { 'windows' } else { 'linux' }
$xg = Join-Path $tmp 'cross-goos'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $xg -Recurse
Check 'no qgate.json go.lintGoos key is no cross-GOOS phase' ($null -eq (Get-GoLintGoos $xg $hostOs))
[IO.File]::WriteAllText((Join-Path $xg 'qgate.json'), '{"go": {"lintGoos": "linux"}}')
Check 'a non-array go.lintGoos is a named config error' ((Get-GoLintGoos $xg $hostOs).Error -match 'must be an array')
[IO.File]::WriteAllText((Join-Path $xg 'qgate.json'), '{"go": {"lintGoos": ["linx"]}}')
Check 'an unknown GOOS in go.lintGoos is a named config error' ((Get-GoLintGoos $xg $hostOs).Error -match "'linx' is not a GOOS")
[IO.File]::WriteAllText((Join-Path $xg 'qgate.json'), "{`"go`": {`"lintGoos`": [`"$hostOs`"]}}")
Check 'the host GOOS alone in go.lintGoos adds no phase' ($null -eq (Get-GoLintGoos $xg $hostOs))
[IO.File]::WriteAllText((Join-Path $xg 'qgate.json'), "{`"go`": {`"lintGoos`": [`"$hostOs`", `"$otherOs`"]}}")
Check 'go.lintGoos keeps only the other GOOS' ((@((Get-GoLintGoos $xg $hostOs).Goos) -join ',') -eq $otherOs)
Set-GoFile (Join-Path $xg "p_$otherOs.go") "package main`n`nimport `"fmt`"`n`nfunc other() {`n`tfmt.Printf(`"%d`", `"not an int`")`n}"
Push-Location $xg
$envBefore = "$env:GOOS|$env:CGO_ENABLED"
$null = go vet ./... 2>&1; $hostVet = $LASTEXITCODE
$xOut = (Invoke-WithGoos $otherOs { go vet ./... 2>&1 } | Out-String); $xVet = $LASTEXITCODE
Pop-Location
Check "a vet defect only $otherOs compiles passes host vet, fails cross vet" (($hostVet -eq 0) -and ($xVet -ne 0) -and ($xOut -match 'Printf')) "host=$hostVet cross=$xVet $xOut"
Check 'Invoke-WithGoos restores GOOS and CGO_ENABLED' ("$env:GOOS|$env:CGO_ENABLED" -eq $envBefore)
$r = (& pwsh -NoProfile -File $gate -Root $xg -All -Full 2>&1 | Out-String)
Check 'go.lintGoos fails the -Full gate on the other-GOOS defect' (($LASTEXITCODE -ne 0) -and ($r -match "\[FAIL\] go vet GOOS=$otherOs")) $r
Set-GoFile (Join-Path $xg "p_$otherOs.go") "package main`n`nimport `"fmt`"`n`nfunc other() {`n`tfmt.Println(`"ok`")`n}"
Push-Location $xg
$xOut = (Invoke-WithGoos $otherOs { go vet ./... 2>&1 } | Out-String); $xVet = $LASTEXITCODE
Pop-Location
Check 'a clean other-GOOS file passes cross vet' ($xVet -eq 0) $xOut

# #44: -Fix rewrites what is fixable and the same run's gate passes; an unfixable defect
# still fails it.
$fx = Join-Path $tmp 'fix'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $fx -Recurse
[IO.File]::WriteAllText((Join-Path $fx 'ugly.go'), "package main`n`n// Ugly is misformatted.`nfunc  Ugly()  int {`nreturn 1`n}`n")
$r = (& pwsh -NoProfile -File $gate -Root $fx -All -Fix 2>&1 | Out-String)
Check '-Fix formats a gofmt violation and the gate passes' `
    (($LASTEXITCODE -eq 0) -and -not (& gofmt -l (Join-Path $fx 'ugly.go'))) $r
Set-GoFile (Join-Path $fx 'ugly.go') "package main`n`nimport `"fmt`"`n`n// Ugly is unfixable.`nfunc Ugly() {`n`tfmt.Printf(`"%d`", `"not an int`")`n}"
$r = (& pwsh -NoProfile -File $gate -Root $fx -All -Fix 2>&1 | Out-String)
Check '-Fix leaves an unfixable defect failing the gate' (($LASTEXITCODE -ne 0) -and ($r -match '\[FAIL\] go vet') -and ($r -match '\[INFO\] fix: gofmt rewrote 0 file')) $r

$tplFmt = @(& gofmt -l (Join-Path $PSScriptRoot 'templates\go-determinism_test.go') 2>&1)
Check 'the property-test template parses and is gofmt-clean' ($LASTEXITCODE -eq 0 -and -not $tplFmt) ($tplFmt -join "`n")

# 3b. Probe: is a -Full run green on a fixture already proven clean? govulncheck
# needs a live vulnerability database, so with no network the full level fails --
# correctly, because unverifiable is not clean. That makes every later check that
# asserts a green -Full run an unmet precondition here, not a defect to report, so
# they [skip] rather than fail, exactly like a check whose tool is off PATH.
$probeOut = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $go -All -Full 2>&1 | Out-String)
$fullGreen = ($LASTEXITCODE -eq 0)
# #84: with no go.lintGoos key there is no cross-GOOS phase at all -- a $null list once ran
# vet and golangci-lint a second time under "GOOS=". The configured side is asserted above.
Check 'a -Full run with no go.lintGoos key runs no GOOS= phase' `
    (($probeOut -match '\[(PASS|FAIL)\] go vet') -and ($probeOut -notmatch 'GOOS=')) $probeOut

# 4. RED: a go vet violation. 5. GREEN: the same file restored.
$main = Join-Path $go 'main.go'
$clean = Get-Content $main -Raw
Set-GoFile $main @'
package main

import "fmt"

// Add returns the sum of a and b.
func Add(a, b int) int { return a + b }

func main() {
	fmt.Printf("%d", "not an int")
	_ = Add(1, 2)
}
'@
$r = Invoke-Gate $go
Check 'go vet violation fails the gate' (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] go vet')) $r.Out
Set-GoFile $main $clean
$r = Invoke-Gate $go
Check 'gate green again after the fix' ($r.Code -eq 0) $r.Out

# A phase killed because the HOST ran out of memory is not a finding about the code,
# but the raw runtime dump reads exactly like one. Reported from the field: a
# `go test -race` failed the same commit twice under parallel load with
# `VirtualAlloc ... errno=1455`, then passed on the third run with nothing changed,
# and all the developer had on screen was a stack blaming a package. Both halves, per
# PLAYBOOK 0.1: the note appears when the output really is an allocation failure, and
# is absent on an ordinary one -- a note printed on every red run is noise, and noise
# is what teaches people to skip the line that mattered.
$oom = Join-Path $tmp 'oom'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $oom -Recurse
$oomTest = Join-Path $oom 'oom_test.go'
# Tab-indented, body on its own line: gofmt expands a one-line func whose body is
# this long, and a fixture that fails gofmt never reaches `go test` at all -- which is
# how the absence half below passed for entirely the wrong reason the first time.
Set-GoFile $oomTest @'
package main

import "testing"

func TestAllocationFailure(t *testing.T) {
	t.Fatal("runtime: VirtualAlloc of 1048576 bytes failed with errno=1455\nfatal error: out of memory")
}
'@
$r = Invoke-Gate $oom
Check 'an out-of-memory failure is named as the host, not the code' `
    (($r.Code -ne 0) -and ($r.Out -match '\[NOTE\].*allocation failure on this machine')) $r.Out
Set-GoFile $oomTest @'
package main

import "testing"

func TestOrdinaryFailure(t *testing.T) {
	t.Fatal("values differ")
}
'@
$r = Invoke-Gate $oom
# The reason has to be the right one: assert the phase that failed is `go test`, or
# this passes on any red run that never got that far.
Check 'an ordinary failure carries no memory note' `
    (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] go test') -and ($r.Out -notmatch '\[NOTE\]')) $r.Out

# quality-gate#41: a package slow enough to time out under CI's -race is named. Parsed
# from `go test`'s own `ok` lines -- a fixture really sleeping 20s is not worth it here.
# Both sides: 27.252s (the reporting repo's package) warns, 19.9s and a cached line do not.
$slow = @(Get-SlowGoPackages @"
ok  	example.com/m/sim	27.252s
ok  	example.com/m/fast	19.900s
ok  	example.com/m/cached	(cached)
FAIL	example.com/m/broken	31.000s
"@ 600)
Check 'a go test package over 1/30 of the timeout is warned about, only that one' `
    (($slow.Count -eq 1) -and ($slow[0] -match '^\[WARN\] slow tests: example\.com/m/sim took 27\.252s')) ($slow -join "`n")
# quality-gate#42: CI steps that run Go for a target the gate never builds are named.
# The workflow is the reporting repo's shape: GOARCH set in a step `env:` block, a
# cross-GOOS lint, and -race runs, which the gate covers itself.
$ci = Join-Path $tmp 'ci parity'
New-Item -ItemType Directory -Path (Join-Path $ci '.github\workflows') -Force | Out-Null
Set-Content (Join-Path $ci '.github\workflows\go.yml') @'
jobs:
  go:
    steps:
      - name: Lint (windows build tags)
        env:
          GOOS: windows
        run: golangci-lint run ./...
      - name: Test with race detector
        run: go test ./... -race -short
      - name: Test
        run: go test -race ./...
      - name: Determinism canary on GOARCH=386
        env:
          GOARCH: "386"
          CGO_ENABLED: "0"
        run: go test -count=1 ./internal/fixed ./internal/sim
      - name: Build only
        env:
          GOARCH: arm64
        run: go build ./...
'@
$gaps = @(Get-CiGoGaps $ci 'windows' 'amd64' '')
Check 'a CI Go step for another GOARCH is named, same-host and build-only steps are not' `
    (($gaps.Count -eq 1) -and ($gaps[0] -match "step 'Determinism canary on GOARCH=386' runs Go with GOARCH=386")) ($gaps -join "`n")
$gaps = @(Get-CiGoGaps $ci 'linux' 'amd64' '')
Check 'the cross-GOOS lint is a gap on a host of the other OS' `
    (($gaps.Count -eq 2) -and ($gaps[0] -match "'Lint \(windows build tags\)' runs Go with GOOS=windows")) ($gaps -join "`n")
$gaps = @(Get-CiGoGaps $ci 'windows' 'amd64' "`$env:GOARCH='386'; `$env:CGO_ENABLED='0'; go vet ./internal/...")
Check 'a variant declared as a qgate.json check is not a gap' ($gaps.Count -eq 0) ($gaps -join "`n")
Check 'a repo without workflows has no CI parity gaps' (@(Get-CiGoGaps $go 'windows' 'amd64' '').Count -eq 0) ''

# 6. RED: an unchecked error -- only golangci-lint catches this one, so it
#    proves the linter phase is live rather than merely present.
if (Get-Command golangci-lint -ErrorAction SilentlyContinue) {
    Set-GoFile $main @'
package main

import "os"

// Add returns the sum of a and b.
func Add(a, b int) int { return a + b }

func main() {
	os.WriteFile("x.txt", nil, 0o600)
	_ = Add(1, 2)
}
'@
    $r = Invoke-Gate $go
    Check 'unchecked error fails the gate' (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] golangci-lint')) $r.Out
    Set-GoFile $main $clean
} else {
    Write-Output '[skip] golangci-lint not on PATH'
}

# 7. Provenance: every phase names the marker that created it.
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $go -All -Why 2>&1 | Out-String)
Check 'provenance names the found marker' ($out -match '\[WHY\] go .*found go\.mod') $out
Check 'provenance names an absent stack' ($out -match '\[WHY\] python -- absent') $out

}

if (Want 'core') {
# 8. Fail closed: an unusable root is a failure, never "nothing to check".
$r = Invoke-Gate (Join-Path $tmp 'does-not-exist')
Check 'unusable root fails closed' ($r.Code -ne 0) $r.Out

# 9. A present-but-unverifiable stack must FAIL, never pass silently.
$web = Join-Path $tmp 'web'
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') $web -Recurse
$r = Invoke-Gate $web
Check 'web without node_modules fails loudly' (($r.Code -ne 0) -and ($r.Out -match 'node_modules missing')) $r.Out

}

if (Want 'wiring') {
# 10. Wiring fills the frontend gap: a phase whose config is absent is skipped, so
# before this a web repo with no eslint/stylelint config passed in silence. A config
# the project already has must survive a re-run untouched.
$wire = Join-Path $tmp 'wire'
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') $wire -Recurse
git -C $wire init -q 2>$null
$installer = Join-Path $PSScriptRoot 'install.ps1'
& pwsh -NoProfile -File $installer -Target $wire -NoRun -NoHook *> $null
$eslintCfg = Join-Path $wire 'eslint.config.js'
Check 'wire installs the frontend linter configs' `
    ((Test-Path $eslintCfg) -and (Test-Path (Join-Path $wire '.stylelintrc.json')))
Set-Content $eslintCfg 'mine' -NoNewline
& pwsh -NoProfile -File $installer -Target $wire -NoRun -NoHook *> $null
Check 'wire keeps a config the project already had' ((Get-Content $eslintCfg -Raw) -eq 'mine')

}

if (Want 'rust') {
# 11. Rust is checked for real now, red then green like Go.
$rust = Join-Path $tmp 'rust'
Copy-Item (Join-Path $PSScriptRoot 'testdata\rust-fixture') $rust -Recurse
$r = Invoke-Gate $rust
Check 'clean rust fixture passes' ($r.Code -eq 0) $r.Out
$rsMain = Join-Path $rust 'src\main.rs'
$rsClean = Get-Content $rsMain -Raw
# Badly formatted AND clippy-hostile: `== true` is a clippy error, the spacing is
# a rustfmt error. Either one alone would prove only half the pipeline.
[IO.File]::WriteAllText($rsMain, 'fn main() {  let x = true; if x == true { println!("y"); } }' + "`n")
$r = Invoke-Gate $rust
Check 'rust violation fails the gate' ($r.Code -ne 0) $r.Out
[IO.File]::WriteAllText($rsMain, $rsClean)
$r = Invoke-Gate $rust
Check 'rust green again after the fix' ($r.Code -eq 0) $r.Out

}

if ((Want 'dotnet') -or (Want 'dotnet2') -or (Want 'dotnet3')) {
# 11b. .NET, red then green -- and then the two verdicts that are NOT red: a project
# whose references live in a game install this machine does not have, and one targeting
# an SDK major nobody here has. Both are gaps in the machine, and reporting them as a
# broken build would teach people to ignore the build phase.
$dnSdks = @(if (Get-Command dotnet -ErrorAction SilentlyContinue) { (& dotnet --list-sdks 2>$null) | Where-Object { $_ } })
if ($dnSdks) {
    $dn = Join-Path $tmp 'dotnet'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dn -Recurse
    $dnProj = Join-Path $dn 'Fixture.csproj'
    $dnCs = Join-Path $dn 'Greeter.cs'
    $dnProjClean = [IO.File]::ReadAllText($dnProj)
    $dnCsClean = [IO.File]::ReadAllText($dnCs)
    # Three parts, each its own job in a parallel run (#84); each part works on its own copies.
    if (Want 'dotnet') {
    $r = Invoke-Gate $dn
    Check 'clean dotnet fixture passes' ($r.Code -eq 0) $r.Out
    $dnFullOut = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dn -All -Full 2>&1 | Out-String)
    $dnFullCode = $LASTEXITCODE
    Check 'clean dotnet fixture passes at the full level' ($dnFullCode -eq 0) $dnFullOut
    # `test` and `vuln` are conditional, and an omitted phase used to read exactly like a
    # passing one: the report could not tell "checked, clean" from "never asked". -Full is
    # what CI and the generated hook run, so that is where the difference is spelled out.
    Check 'the full level says which phases do not apply here' `
        (($dnFullOut -match '\[SKIP\] test -- no test project') -and
            ($dnFullOut -match '\[SKIP\] vuln -- no package references')) $dnFullOut
    # The absence half: naming them must not turn a green run red, and must not be mistaken
    # for the run having verified nothing -- the zero-phase invariant counts phases that RAN.
    Check 'naming an inapplicable phase is not a failure and not an empty run' `
        (($dnFullCode -eq 0) -and ($dnFullOut -notmatch 'no check phase ran') -and
            ($dnFullOut -match '\[PASS\] build')) $dnFullOut

    # One space where eight belong. The fix hint matters as much as the finding: every
    # line names file(line,col) and not one of them names the command that fixes them.
    [IO.File]::WriteAllText($dnCs, $dnCsClean.Replace('        return $"Hello', ' return $"Hello'))
    $r = Invoke-Gate $dn
    Check 'a whitespace violation fails the dotnet gate' `
        (($r.Code -ne 0) -and ($r.Out -match 'WHITESPACE') -and ($r.Out -match 'fix: dotnet format whitespace')) $r.Out
    Check 'a whitespace violation is not reported as a compile error' ($r.Out -notmatch 'error CS') $r.Out

    [IO.File]::WriteAllText($dnCs, $dnCsClean.Replace('return $"Hello, {name}!";', 'int x = "s"; return $"Hello, {name}!{x}";'))
    $r = Invoke-Gate $dn
    Check 'a compile error fails the dotnet gate' (($r.Code -ne 0) -and ($r.Out -match 'error CS0029')) $r.Out
    Check 'a compile error is not reported as a formatting problem' ($r.Out -notmatch 'WHITESPACE') $r.Out

    # Both defects in one file. Reported from the field twice: first `[FAIL] format` and NO
    # build line at all, then -- once the skip was on the record -- 1091 whitespace errors
    # in an upstream fork skipping the build that held the real bug. Whitespace is not
    # semantic: it fails the run, and the build still runs and speaks for itself.
    [IO.File]::WriteAllText($dnCs, $dnCsClean.Replace(
            '        return $"Hello, {name}!";', ' int x = "s"; return $"Hello, {name}!{x}";'))
    $r = Invoke-Gate $dn
    Check 'a format failure does not skip the build' `
        (($r.Code -ne 0) -and ($r.Out -match 'FAIL\] format') -and ($r.Out -match 'FAIL\] build') -and
            ($r.Out -match 'error CS0029')) $r.Out
    # The absence half: the old skip line, which hid the compile error behind whitespace.
    Check 'the build after a format failure is not reported as skipped' ($r.Out -notmatch 'SKIP\] build -- not run') $r.Out
    [IO.File]::WriteAllText($dnCs, $dnCsClean)

    # A game mod's <Reference> HintPath points into a Steam directory, and CI and half
    # the developer machines do not have one. Read by evaluating the project, never by
    # building it: the build would report forty MSB3245 lines about the code instead.
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace('</Project>', @"
  <ItemGroup>
    <Reference Include="Ghost"><HintPath>C:\does\not\exist\Ghost.dll</HintPath></Reference>
  </ItemGroup>
</Project>
"@))
    $r = Invoke-Gate $dn
    Check 'a reference the machine does not have is a skip with the reason, not a red build' `
        (($r.Code -eq 0) -and ($r.Out -match 'reference\(s\) missing') -and ($r.Out -match 'Ghost\.dll')) $r.Out
    Check 'a missing reference is not blamed on the code' `
        (($r.Out -notmatch 'error CS') -and ($r.Out -notmatch 'error MSB')) $r.Out

    # ...and the HintPath is usually RELATIVE to the csproj (`..\..\lib\X.dll` in a real
    # test project), so both halves: a relative hint that resolves must not be called
    # missing, and one that does not must still be found. Resolving it against the
    # process directory instead of the project directory passes the first half and fails
    # the second -- or worse, silently skips every project on a machine that has
    # everything. The payload is a real managed assembly because the build phase runs
    # right after and a file of garbage bytes would fail it for the wrong reason.
    $dnLib = Join-Path $tmp 'lib'
    New-Item -ItemType Directory $dnLib -Force | Out-Null
    Copy-Item ([psobject].Assembly.Location) (Join-Path $dnLib 'Ghost.dll') -Force
    $dnRelRef = $dnProjClean.Replace('</Project>', @"
  <ItemGroup>
    <Reference Include="Ghost"><HintPath>..\lib\Ghost.dll</HintPath></Reference>
  </ItemGroup>
</Project>
"@)
    [IO.File]::WriteAllText($dnProj, $dnRelRef)
    $r = Invoke-Gate $dn
    Check 'a relative HintPath that resolves is not reported as missing' `
        (($r.Code -eq 0) -and ($r.Out -notmatch 'reference\(s\) missing')) $r.Out
    Remove-Item (Join-Path $dnLib 'Ghost.dll') -Force
    $r = Invoke-Gate $dn
    Check 'a relative HintPath that resolves to nothing is a skip that names the file' `
        (($r.Code -eq 0) -and ($r.Out -match 'reference\(s\) missing') -and ($r.Out -match 'Ghost\.dll')) $r.Out
    Check 'a missing relative reference is not blamed on the code' `
        (($r.Out -notmatch 'error CS') -and ($r.Out -notmatch 'error MSB')) $r.Out

    # A HintPath into another project's bin/ INSIDE the repository is a build-order gap,
    # not a missing game. Reported from the field: `..\Auga\bin\API\AugaAPI.dll`, the
    # output of a sibling project, was reported as "game/SDK not installed".
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace('</Project>', @"
  <ItemGroup>
    <Reference Include="Sibling"><HintPath>Other\bin\API\Sibling.dll</HintPath></Reference>
  </ItemGroup>
</Project>
"@))
    $r = Invoke-Gate $dn
    Check 'a missing in-repo build output names the build order, not the game' `
        (($r.Code -eq 0) -and ($r.Out -match 'Sibling\.dll\) -- built by another project in this repo') -and
            ($r.Out -notmatch 'game/SDK not installed')) $r.Out
    [IO.File]::WriteAllText($dnProj, $dnProjClean)

    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace('net8.0', 'net99.0'))
    $r = Invoke-Gate $dn
    Check 'a target framework no installed SDK can build is a skip that names both' `
        (($r.Code -eq 0) -and ($r.Out -match 'needs \.NET SDK 99\.x') -and ($r.Out -match 'installed \d')) $r.Out
    Check 'an SDK the machine lacks is not reported as an error' ($r.Out -notmatch 'error ') $r.Out

    # A multi-targeted project leaves the SINGULAR property empty, so reading only that
    # one reports nothing and builds the project anyway -- green, on a TFM no SDK here
    # can produce.
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace(
            '<TargetFramework>net8.0</TargetFramework>', '<TargetFrameworks>net8.0;net99.0</TargetFrameworks>'))
    $r = Invoke-Gate $dn
    Check 'one unbuildable TFM in a multi-targeted project is a skip that names it' `
        (($r.Code -eq 0) -and ($r.Out -match 'needs \.NET SDK 99\.x')) $r.Out
    Check 'a multi-targeted project is not failed over the TFM nobody has' `
        (($r.Out -notmatch 'error ') -and ($r.Out -notmatch 'reference\(s\) missing')) $r.Out

    # ...but a csproj msbuild cannot even evaluate IS a defect in the repository, and it
    # has to land as one rather than as another environment excuse.
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace('</Project>', '<Nope'))
    $r = Invoke-Gate $dn
    Check 'an unparseable csproj fails the gate' (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] refs')) $r.Out
    Check 'an unparseable csproj is not called a missing reference' ($r.Out -notmatch 'reference\(s\) missing') $r.Out
    [IO.File]::WriteAllText($dnProj, $dnProjClean)

    # The fast lane. Measured on two real mods: 1396 and 447 whitespace violations, so
    # a whole-project format check on every commit blocks the repository forever. Both
    # halves, or "narrowed correctly" is indistinguishable from "format switched off":
    # the committed violation must be ignored while nothing .cs changed, and must be
    # found the moment it is touched.
    $dnFast = Join-Path $tmp 'dotnet-fast'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnFast -Recurse
    $ugly = Join-Path $dnFast 'Ugly.cs'
    [IO.File]::WriteAllText($ugly, "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n}`r`n")
    git -C $dnFast init -q 2>$null
    git -C $dnFast add -A 2>$null
    git -C $dnFast -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    [IO.File]::WriteAllText((Join-Path $dnFast 'notes.md'), "not a .cs file`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnFast 2>&1 | Out-String)
    $dnFastCode = $LASTEXITCODE
    Check 'the fast lane does not format a project whose .cs files nobody touched' `
        (($dnFastCode -eq 0) -and ($out -match '\[SKIP\] format Fixture\.csproj') -and ($out -notmatch 'WHITESPACE')) `
        "code=$dnFastCode $out"
    # ...and it still builds it, or the narrowing would have dropped the stack entirely.
    Check 'the fast lane still builds a project it did not format' ($out -match '\[PASS\] build') $out
    [IO.File]::WriteAllText($ugly, "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n  public static int Two() => 2;`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnFast 2>&1 | Out-String)
    $dnTouchCode = $LASTEXITCODE
    Check 'touching a .cs file brings the whitespace check back' `
        (($dnTouchCode -ne 0) -and ($out -match 'WHITESPACE') -and ($out -match 'Ugly\.cs')) "code=$dnTouchCode $out"
    # --include is resolved against the CURRENT DIRECTORY and an absolute path matches
    # nothing at all -- silently, exit 0. That is the shape this half would catch.
    Check 'the narrowed format check is not a silent no-op' ($out -notmatch '\[SKIP\] format') $out

    # ...and the file added inside a BRAND NEW directory, which is the shape the narrowing
    # could not see at all. `git status --porcelain` collapses a wholly untracked directory
    # to one entry, `NewFolder/`, so the changed-path list held a directory, the `*.cs`
    # filter dropped it, and the fast lane reported `no changed .cs files` and exited 0
    # over a real violation that `-All` finds. Get-ChangedPaths is what every stack narrows
    # through, so this was the fast lane's blind spot everywhere, not just here.
    $dnNew = Join-Path $tmp 'dotnet-newdir'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnNew -Recurse
    git -C $dnNew init -q 2>$null
    git -C $dnNew add -A 2>$null
    git -C $dnNew -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    New-Item -ItemType Directory -Path (Join-Path $dnNew 'NewFolder') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dnNew 'NewFolder\Ugly.cs'),
        "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnNew 2>&1 | Out-String)
    $dnNewCode = $LASTEXITCODE
    Check 'a violation inside a brand new directory is seen by the fast lane' `
        (($dnNewCode -ne 0) -and ($out -match 'WHITESPACE') -and ($out -match 'Ugly\.cs')) "code=$dnNewCode $out"
    # The absence half, and it is the whole bug: the run used to be green with this line.
    Check 'a file in a new directory is not called no changed .cs files' `
        ($out -notmatch 'no changed \.cs files') $out

    # -Baseline narrows the whole-project format pass too. Reported from the field: an
    # upstream fork carries 1091 whitespace errors nobody may reformat, and -Baseline was
    # wired to golangci alone, so `-Full -Baseline HEAD` failed exactly like `-Full`.
    # $dnFast has a committed Ugly.cs; restored to HEAD it is a violation nobody touched.
    $dnBase = Join-Path $tmp 'dotnet-baseline'
    Copy-Item $dnFast $dnBase -Recurse
    git -C $dnBase checkout -q -- Ugly.cs 2>$null
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnBase -All -Full -Baseline HEAD 2>&1 | Out-String)
    $dnBaseCode = $LASTEXITCODE
    Check '-Baseline leaves a committed format violation alone at the full level' `
        (($dnBaseCode -eq 0) -and ($out -match '\[SKIP\] format Fixture\.csproj -- no changed \.cs files since HEAD') -and
            ($out -match '\[PASS\] build')) "code=$dnBaseCode $out"
    # The other half: the file touched since the baseline is still judged, whole.
    [IO.File]::WriteAllText((Join-Path $dnBase 'Ugly.cs'),
        "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n  public static int Two() => 2;`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnBase -All -Full -Baseline HEAD 2>&1 | Out-String)
    $dnBaseCode = $LASTEXITCODE
    Check '-Baseline still judges a file touched since the baseline' `
        (($dnBaseCode -ne 0) -and ($out -match 'Ugly\.cs\(5,') -and ($out -match 'Ugly\.cs\(6,')) "code=$dnBaseCode $out"

    # Two or more dotnet projects in one run share ONE `dotnet format` pass over a
    # temporary solution: measured on ContentTool (13 csproj, warm), 25.6s of per-project
    # calls against 3.3-3.6s for one call over the same projects. The saving is worthless
    # if the report stops naming the project that is actually dirty, so both halves --
    # the clean project passes, the dirty one fails with ITS csproj in the fix line.
    $dnMulti = Join-Path $tmp 'dotnet-multi'
    foreach ($n in 'A', 'B') {
        $d = Join-Path $dnMulti $n
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d "$n.csproj"), $dnProjClean)
        [IO.File]::WriteAllText((Join-Path $d 'Greeter.cs'), $dnCsClean)
    }
    $uglyOne = "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n}`r`n"
    [IO.File]::WriteAllText((Join-Path $dnMulti 'B\Ugly.cs'), $uglyOne)
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnMulti -All 2>&1 | Out-String)
    $dnMultiCode = $LASTEXITCODE
    Check 'one format pass over two projects still blames the project that is dirty' `
        (($dnMultiCode -ne 0) -and ($out -match '\[PASS\] format \(\d+\.\ds, one pass over 2 projects\)') -and
            ($out -match '\[FAIL\] format \(shared pass\)') -and ($out -match 'B\\Ugly\.cs') -and
            ($out -match 'fix: dotnet format whitespace B\.csproj')) "code=$dnMultiCode $out"
    # The absence half, and it is the whole risk of sharing one pass: the clean project
    # must not inherit its neighbour's violations, and no phase may print 0.0s for work
    # that really took three seconds somewhere else.
    Check 'a shared format pass does not blame the clean project or claim zero time' `
        (($out -notmatch 'fix: dotnet format whitespace A\.csproj') -and ($out -notmatch 'format \(0\.0s')) $out
    # ...and the temporary solution is by-product: it lives outside the repository and
    # does not survive the run that made it.
    $dnSlnKey = "quality-gate-fmt-$(Get-PathKey (Resolve-Path $dnMulti).Path)-*"
    Check 'the temporary solution is gone when the run ends' `
        (-not (Get-ChildItem ([IO.Path]::GetTempPath()) -Filter $dnSlnKey -Directory -ErrorAction SilentlyContinue)) `
        $dnSlnKey

    # ...and a whitespace failure in the FIRST project must not skip the second one: the
    # other stacks are where the semantic checks live. Red run, both stacks on the record.
    $dnMultiSoft = Join-Path $tmp 'dotnet-multi-soft'
    Copy-Item $dnMulti $dnMultiSoft -Recurse
    Move-Item (Join-Path $dnMultiSoft 'B\Ugly.cs') (Join-Path $dnMultiSoft 'A\Ugly.cs')
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnMultiSoft -All 2>&1 | Out-String)
    $dnMultiSoftCode = $LASTEXITCODE
    Check 'a format failure in one project does not skip the next project' `
        (($dnMultiSoftCode -ne 0) -and ($out -match '\[FAIL\] dotnet A/') -and ($out -match '\[PASS\] dotnet B/')) `
        "code=$dnMultiSoftCode $out"
    Check 'a format failure does not mark later stacks as not run' ($out -notmatch 'an earlier stack failed') $out

    # The fast lane narrows the same pass with --include, and the narrowing is what keeps
    # a repository with committed violations committable: B carries one nobody touched,
    # A's touched file carries one, and only A's is a verdict.
    $dnMultiFast = Join-Path $tmp 'dotnet-multi-fast'
    Copy-Item $dnMulti $dnMultiFast -Recurse
    [IO.File]::WriteAllText((Join-Path $dnMultiFast 'A\Ugly.cs'), $uglyOne)
    git -C $dnMultiFast init -q 2>$null
    git -C $dnMultiFast add -A 2>$null
    git -C $dnMultiFast -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    [IO.File]::WriteAllText((Join-Path $dnMultiFast 'A\Ugly.cs'),
        "namespace Fixture;`r`n`r`npublic static class Ugly`r`n{`r`n public static int One() => 1;`r`n  public static int Two() => 2;`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnMultiFast 2>&1 | Out-String)
    $dnMultiFastCode = $LASTEXITCODE
    Check 'the fast lane judges the touched project' `
        (($dnMultiFastCode -ne 0) -and ($out -match 'A\\Ugly\.cs') -and
            ($out -match 'fix: dotnet format whitespace A\.csproj')) "code=$dnMultiFastCode $out"
    # The absence half: an --include list that matched nothing (an absolute path does
    # exactly that, silently) would leave B's committed violation to be reported instead.
    Check 'the fast lane does not report the violation nobody touched' `
        ($out -notmatch 'B\\Ugly\.cs') $out

    # A project no installed SDK can build cannot go into the solution -- it fails the
    # LOAD, which would turn one machine gap into a formatting verdict on every project
    # beside it. It is still reported as the skip it always was, and the other two are
    # still checked in one pass.
    $dnMultiSdk = Join-Path $tmp 'dotnet-multi-sdk'
    Copy-Item $dnMulti $dnMultiSdk -Recurse
    Remove-Item (Join-Path $dnMultiSdk 'B\Ugly.cs') -Force
    $dnC = Join-Path $dnMultiSdk 'C'
    New-Item -ItemType Directory -Path $dnC -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dnC 'C.csproj'), $dnProjClean.Replace('net8.0', 'net99.0'))
    [IO.File]::WriteAllText((Join-Path $dnC 'Greeter.cs'), $dnCsClean)
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnMultiSdk -All 2>&1 | Out-String)
    $dnMultiSdkCode = $LASTEXITCODE
    Check 'a project no SDK here can build is left out of the shared pass, not run through it' `
        (($dnMultiSdkCode -eq 0) -and ($out -match 'one pass over 2 projects') -and
            ($out -match 'needs \.NET SDK 99\.x')) "code=$dnMultiSdkCode $out"
    # The absence half: leaving it out must not turn into an error, and must not quietly
    # drop the formatting check for the projects that CAN be loaded.
    Check 'leaving the unbuildable project out is not an error and not a dropped check' `
        (($out -notmatch 'error ') -and ($out -match '\[PASS\] format \(shared pass\)')) $out

    # A Unity project's csproj are editor output, not dotnet projects. Reported from the
    # field: six of them became six stacks of [UNKNOWN] and 260-reference skips, and they
    # broke the shared format solution. One SKIP for the Unity project, left out of the
    # shared pass, which still covers the two real projects beside it.
    $dnUnity = Join-Path $tmp 'dotnet-unity'
    Copy-Item $dnMultiSdk $dnUnity -Recurse
    Remove-Item (Join-Path $dnUnity 'C') -Recurse -Force
    $dnU = Join-Path $dnUnity 'U'
    New-Item -ItemType Directory -Path (Join-Path $dnU 'ProjectSettings'), (Join-Path $dnU 'Assets') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dnU 'ProjectSettings\ProjectVersion.txt'), "m_EditorVersion: 2022.3.62f1`n")
    foreach ($n in 'Assembly-CSharp', 'Assembly-CSharp-Editor') {
        [IO.File]::WriteAllText((Join-Path $dnU "$n.csproj"), $dnProjClean.Replace('</Project>', '<Nope'))
    }
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnUnity -All 2>&1 | Out-String)
    $dnUnityCode = $LASTEXITCODE
    Check 'a Unity project is one skip, and the shared pass still covers the real projects' `
        (($dnUnityCode -eq 0) -and (@($out -split "`r?`n" | Where-Object { $_ -match '\[SKIP\] dotnet U/ .*Unity-generated' }).Count -eq 1) -and
            ($out -match 'one pass over 2 projects')) "code=$dnUnityCode $out"
    # The absence half: an unparseable Unity csproj would fail `refs` if it were a stack.
    Check 'Unity-generated csproj are not stacks' `
        (($out -notmatch 'Assembly-CSharp') -and ($out -notmatch 'could not load its solution')) $out

    # The whole-project check is the one CI and the generated pre-commit hook run, and on
    # a real mod it is 1397 WHITESPACE lines -- 323k chars, which the report's global
    # 6000-char truncation then cut to 27 lines and a byte count: no total, no file count,
    # and the cut landing mid-line. Capped at twenty with the real numbers beside it.
    $dnFlood = Join-Path $tmp 'dotnet-flood'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnFlood -Recurse
    # One space where four belong, thirty times: methods M1..M30 land on lines 5..34.
    $floodBody = ((1..30 | ForEach-Object { " public static int M$_() => $_;" }) -join "`r`n")
    [IO.File]::WriteAllText((Join-Path $dnFlood 'Flood.cs'),
        "namespace Fixture;`r`n`r`npublic static class Flood`r`n{`r`n$floodBody`r`n}`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnFlood -All 2>&1 | Out-String)
    $dnFloodCode = $LASTEXITCODE
    Check 'a format flood is capped and counted' `
        (($dnFloodCode -ne 0) -and ($out -match 'format: 3\d violation\(s\) in 1 file\(s\) -- showing first 20')) `
        "code=$dnFloodCode $out"
    # The absence half, and it is the whole point: a cap that printed all thirty would
    # satisfy the count above. M1 is on line 5 and must still be there; M26..M30 are on
    # lines 30..34, past the cap, and must not be.
    Check 'the format flood stops at twenty lines' `
        ((@($out -split "`r?`n" | Where-Object { $_ -match 'error WHITESPACE' }).Count -le 20) -and
            ($out -match 'Flood\.cs\(5,') -and ($out -notmatch 'Flood\.cs\(3[0-4],')) $out

    # The warning count is read out of the BUILD OUTPUT, and an incremental build that
    # compiles nothing prints nothing: reported from the field, `[WARN] RailCheck.csproj:
    # 9 compiler warning(s)` on a cold obj/ and no line at all on the next run of the same
    # commit. The number said whether csc ran, not what the code contains. Two runs of the
    # SAME tree is the whole test -- one run cannot tell the two behaviours apart.
    $dnWarn = Join-Path $tmp 'dotnet-warn'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnWarn -Recurse
    [IO.File]::WriteAllText((Join-Path $dnWarn 'Warned.cs'),
        "namespace Fixture;`r`n`r`npublic static class Warned`r`n{`r`n    public static int One()`r`n    {`r`n        int unused;`r`n        return 1;`r`n    }`r`n}`r`n")
    $dnWarn1 = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnWarn -All -Full 2>&1 | Out-String)
    $dnWarn1Code = $LASTEXITCODE
    $dnWarn2 = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnWarn -All -Full 2>&1 | Out-String)
    $dnWarn2Code = $LASTEXITCODE
    Check 'the full level counts compiler warnings on every run, not only a cold one' `
        (($dnWarn1 -match '\[WARN\] Fixture\.csproj: 1 compiler warning\(s\)') -and
            ($dnWarn2 -match '\[WARN\] Fixture\.csproj: 1 compiler warning\(s\)')) `
        "run1=$dnWarn1`nrun2=$dnWarn2"
    # The absence half: a warning is a note beside a green build, never a compile error and
    # never a red run -- rebuilding from scratch must not change the verdict.
    Check 'a counted warning is not turned into a compile error or a red run' `
        (($dnWarn1Code -eq 0) -and ($dnWarn2Code -eq 0) -and ($dnWarn2 -notmatch 'error CS')) `
        "code1=$dnWarn1Code code2=$dnWarn2Code $dnWarn2"

    # `test` and `vuln` used to exist only where a regex found their marker in the csproj
    # TEXT, so anything imported through Directory.Build.props was invisible: measured, a
    # project whose Microsoft.NET.Test.Sdk and xunit come from there passed `-All -Full`
    # with no `test` phase at all while `dotnet test --no-build` found the failing test and
    # exited 1. Both facts now come from the MSBuild evaluation that already runs. The
    # cheap half of that needs no package and no restore: a project that simply declares
    # itself one, in a csproj whose text does not contain the string the old check hunted.
    $dnTest = Join-Path $tmp 'dotnet-istest'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnTest -Recurse
    [IO.File]::WriteAllText((Join-Path $dnTest 'Fixture.csproj'), $dnProjClean.Replace(
            '<Nullable>enable</Nullable>', "<IsTestProject>true</IsTestProject>`n    <Nullable>enable</Nullable>"))
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnTest -All -Full 2>&1 | Out-String)
    $dnTestCode = $LASTEXITCODE
    Check 'a project that evaluates as a test project gets the test phase' `
        (($dnTestCode -ne 0) -and ($out -match '\[FAIL\] test')) "code=$dnTestCode $out"
    # ...and the red is the test phase speaking, not an earlier phase falling over: a
    # broken build would satisfy "exit non-zero" while proving nothing about detection.
    Check 'the test phase verdict is not standing on an earlier failure' `
        ($out -notmatch '\[FAIL\] (refs|format|build)') $out

    # A multi-targeted project evaluates with TargetFramework EMPTY, so every item inside
    # an ItemGroup conditioned on it is absent from the answer: measured on
    # `net8.0;net8.0-windows`, the conditioned <Reference> came back as `"Reference": []`,
    # the missing game DLL went unreported, and the gate BUILT the project -- turning the
    # [SKIP] it owed the reader into CS0246. References are evaluated per TFM now.
    [IO.File]::WriteAllText($dnProj, $dnProjClean.Replace(
            '<TargetFramework>net8.0</TargetFramework>',
            '<TargetFrameworks>net8.0;net8.0-windows</TargetFrameworks>').Replace('</Project>', @"
  <ItemGroup Condition="'`$(TargetFramework)' == 'net8.0-windows'">
    <Reference Include="Ghost"><HintPath>C:\does\not\exist\Ghost.dll</HintPath></Reference>
  </ItemGroup>
</Project>
"@))
    $r = Invoke-Gate $dn
    Check 'a reference conditioned on one target framework is still evaluated' `
        (($r.Code -eq 0) -and ($r.Out -match 'reference\(s\) missing') -and ($r.Out -match 'Ghost\.dll')) $r.Out
    # The absence half: the old behaviour was to see no reference and build anyway.
    Check 'a conditioned missing reference is not built over' `
        (($r.Out -notmatch 'error CS') -and ($r.Out -notmatch 'error MSB') -and ($r.Out -notmatch '\[PASS\] build')) $r.Out
    [IO.File]::WriteAllText($dnProj, $dnProjClean)

    # The other half of the same defect, plus the report bug it was hiding behind. The
    # package here is declared ONLY in Directory.Build.props, so the vulnerability gate
    # used to skip the project outright; and with the source unreachable that gate answers
    # [UNKNOWN] -- which the summary of a PASSING stack then dropped, because its filter
    # kept [PASS]/[WARN]/[SKIP] and nothing else. Measured: `[PASS] dotnet ... [PASS]
    # build`, exit 0, over a question nobody asked. The package has to come down once
    # before the source is broken, so a machine with no source skips this out loud.
    $dnPkg = Join-Path $tmp 'dotnet-props'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnPkg -Recurse
    [IO.File]::WriteAllText((Join-Path $dnPkg 'Directory.Build.props'), @'
<Project>
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
  </ItemGroup>
</Project>
'@)
    Push-Location $dnPkg
    & dotnet restore Fixture.csproj -nologo *> $null
    $dnRestored = ($LASTEXITCODE -eq 0)
    Pop-Location
    if ($dnRestored) {
        # <clear /> plus a port nothing listens on: restore is already satisfied from the
        # global packages folder, `dotnet list package --vulnerable` is not. The retry caps
        # turn NuGet's 18 seconds of backoff into two (measured).
        [IO.File]::WriteAllText((Join-Path $dnPkg 'NuGet.config'), @'
<configuration>
  <packageSources>
    <clear />
    <add key="unreachable" value="http://127.0.0.1:9/v3/index.json" />
  </packageSources>
</configuration>
'@)
        $priorRetry = @($env:NUGET_ENABLE_ENHANCED_HTTP_RETRY, $env:NUGET_ENHANCED_MAX_NETWORK_TRY_COUNT,
            $env:NUGET_ENHANCED_NETWORK_RETRY_DELAY_MILLISECONDS)
        $env:NUGET_ENABLE_ENHANCED_HTTP_RETRY = 'true'
        $env:NUGET_ENHANCED_MAX_NETWORK_TRY_COUNT = '1'
        $env:NUGET_ENHANCED_NETWORK_RETRY_DELAY_MILLISECONDS = '0'
        try {
            $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnPkg -All -Full 2>&1 | Out-String)
            $dnPkgCode = $LASTEXITCODE
        } finally {
            $env:NUGET_ENABLE_ENHANCED_HTTP_RETRY = $priorRetry[0]
            $env:NUGET_ENHANCED_MAX_NETWORK_TRY_COUNT = $priorRetry[1]
            $env:NUGET_ENHANCED_NETWORK_RETRY_DELAY_MILLISECONDS = $priorRetry[2]
        }
        Check 'a package declared only in Directory.Build.props reaches the vulnerability gate' `
            (($dnPkgCode -eq 0) -and ($out -match 'could not check for vulnerable packages')) "code=$dnPkgCode $out"
        Check 'an unperformed check is not dropped from the report of a passing stack' `
            (($out -match '\[PASS\] dotnet') -and ($out -match '\[UNKNOWN\]')) $out
        # ...and it is there because the summary kept it, not because the stack failed and
        # dumped its raw lines -- which is how this would pass while still being broken.
        Check 'the [UNKNOWN] survived the summary, it is not a failure dump' ($out -notmatch '\[FAIL\]') $out
    } else {
        Write-Output '[skip] no NuGet source reachable -- the Directory.Build.props package checks cannot run'
    }

    # The true positive the offline [UNKNOWN] above must not swallow: a restored project with
    # a known-vulnerable package, checked AFTER the analyzer build. That build restores obj/
    # with the injected packages, and `dotnet list package` used to read the result as out of
    # sync -- [UNKNOWN] on every restored project, never a verdict (#74).
    $dnVuln = Join-Path $tmp 'dotnet-vuln'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnVuln -Recurse
    [IO.File]::WriteAllText((Join-Path $dnVuln 'Directory.Build.props'), @'
<Project>
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="12.0.1" />
  </ItemGroup>
</Project>
'@)
    Push-Location $dnVuln
    & dotnet restore Fixture.csproj -nologo *> $null
    # Online means the advisory database answers on the plainly restored project -- asked
    # before the gate, so the gate's own answer is the only thing under test.
    $dnVulnOnline = ($LASTEXITCODE -eq 0) -and
        ((& dotnet list Fixture.csproj package --vulnerable --format json --output-version 1 2>&1 | Out-String) -match '"advisoryurl"')
    Pop-Location
    if ($dnVulnOnline) {
        $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnVuln -All -Full 2>&1 | Out-String)
        if ($out -match 'injection failed[^\r\n]*\bNU\d') {
            Write-Output '[skip] analyzer packages not restorable -- the vulnerable-package check cannot run'
        } else {
            Check 'a known-vulnerable package fails vuln after the analyzer build, not [UNKNOWN]' `
                (($LASTEXITCODE -ne 0) -and ($out -match 'Newtonsoft\.Json 12\.0\.1: High')) $out
        }
        $assets = Get-Content -LiteralPath (Join-Path $dnVuln 'obj\project.assets.json') -Raw
        Check 'the gate leaves obj/project.assets.json without the injected analyzer packages' ($assets -notmatch 'Meziantou') 'obj/ still injected'
    } else {
        Write-Output '[skip] advisory source unreachable -- the vulnerable-package check cannot run'
    }
    }

    if (Want 'dotnet2') {
    # Roslyn analyzers, injected through -p:CustomBeforeMicrosoftCommonProps: not one of
    # these repositories edits its csproj to get static analysis, so the gate carries the
    # packages into the build and leaves the work tree alone. Four questions: does anything
    # come out at all, does the fast lane stay out of it, do the Unity rules stay away from
    # a project that has never heard of UnityEngine, and -- the one that matters -- does a
    # diagnostic stay a warning instead of reddening a build that compiles.
    $dnAna = Join-Path $tmp 'dotnet-analyzers'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnAna -Recurse
    # CA1001 (SDK) and MA0084 (Meziantou) in one file: two diagnostics prove both the
    # properties and the injected package arrived. The SDK half has been CA1310 and, before
    # that, MA0074; both are now silenced. CA1001 is silenced too, but only under
    # QGateUnity, and this fixture references no UnityEngine -- the assets check below is
    # the same fact from the other side -- so it is still a live SDK rule here, and it
    # doubles as the proof that the Unity suppression did not go global.
    # Prefix() is a Harmony patch, spelled the only way Harmony accepts -- the leading
    # underscores are the injector's API, and CA1707 asking for them to be renamed is the
    # single loudest false positive this gate can produce on a game mod.
    [IO.File]::WriteAllText((Join-Path $dnAna 'Probe.cs'), @'
namespace Fixture;

public sealed class Probe
{
    private readonly string tag = "probe";

    private readonly System.IO.MemoryStream buffer = new();

    public string Tag => tag;

    public int Length => (int)buffer.Length;

    public int Find(string a, string b)
    {
        var tag = a; ;
        return tag.IndexOf(b);
    }

    public static bool Prefix(object __instance) => __instance != null;
}

internal class Sealable
{
    public int Value => 1;
}
'@)
    # Fast lane FIRST, on a cold obj/: an incremental build that compiles nothing prints no
    # warnings either, so running it after the full level would pass without proving a thing.
    $r = Invoke-Gate $dnAna
    $anaFastOut = $r.Out
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnAna -All -Full 2>&1 | Out-String)
    $dnAnaCode = $LASTEXITCODE
    # Only a RESTORE failure is a reason to skip: an analyzer error that read as a failed
    # injection is the defect the `;;` in Find() above exists to catch.
    if ($out -match 'injection failed[^\r\n]*\bNU\d') {
        Write-Output '[skip] analyzer packages could not be restored -- the injection checks cannot run'
    }
    else {
        # MA0037 (empty statement) is ERROR by default in Meziantou. Reported from the
        # field: one stray `;;` failed the analyzer build, the gate called it a failed
        # injection and dropped every analyzer finding. It is a finding like any other.
        Check 'an error-severity analyzer default does not drop the analyzer pass' `
            (($out -notmatch 'injection failed') -and ($out -match 'analyzer diagnostic\(s\)[^\r\n]*MA0037')) $out
        Check 'analyzer diagnostics are reported at the full level' `
            (($out -match 'analyzer diagnostic\(s\)') -and ($out -match 'MA0084') -and ($out -match 'CA1001')) $out
        # The second noise pass, asserted as absence: the probe's Find() is still a
        # culture-sensitive-looking IndexOf and Probe itself is still a candidate for
        # "could be sealed", so a NoWarn list that stopped being applied would show up here.
        Check 'the second-pass suppressions stay silent' `
            (($out -notmatch 'CA1310') -and ($out -notmatch 'CA1852')) $out
        # The rule that had to go. Harmony patch parameters are named __instance, __result,
        # ___privateField and __state because Harmony reads those names; CA1707 asks for
        # every one of them to be renamed, which breaks the patch. 134 hits on the live
        # repositories, not one of them a defect.
        Check 'CA1707 stays silent about a Harmony patch parameter' `
            ($out -notmatch 'CA1707') $out
        # The point of this pass. The owner asked for the volume first, and a rule that goes
        # red before anybody has read it is a rule people learn to route around.
        Check 'analyzer diagnostics are a warning, not a failure' `
            (($dnAnaCode -eq 0) -and ($out -match '\[PASS\] build') -and ($out -notmatch '\[FAIL\]')) "code=$dnAnaCode $out"
        # The compiler's own count is separate: one number for both would read as though csc
        # had suddenly grown 300 opinions about code it used to accept.
        Check 'analyzer diagnostics are not counted as compiler warnings' `
            ($out -notmatch 'compiler warning\(s\)') $out
        Check 'the fast lane does not pay for the analyzer build' `
            (($anaFastOut -notmatch 'analyzer diagnostic') -and ($anaFastOut -notmatch 'MA0084')) $anaFastOut
        # Unity rules on a project with no UnityEngine anywhere are noise. The assets file used
        # to be the witness, but the gate now restores obj/ back to the repository's own state
        # (#74). CA1001 is: qgate.analyzers.props silences it under the same QGateUnity
        # condition that adds Microsoft.Unity.Analyzers, so a live CA1001 beside MA0084 means
        # the analyzers arrived and the Unity half did not.
        Check 'Unity analyzers are not injected into a project with no UnityEngine reference' `
            (($out -match 'MA0084') -and ($out -match 'CA1001') -and ($out -notmatch '\bUNT\d')) $out
    }

    # And the failure this feature must survive. Injecting PackageReferences forces a
    # restore, and a repository that pins its packages with a lock file answers NU1004 --
    # the same shape as an offline machine or a private feed. Reported as a warning, and
    # the build is repeated without the analyzers: nothing here may become unbuildable
    # because the gate wanted an opinion about the code.
    $dnLock = Join-Path $tmp 'dotnet-lock'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnLock -Recurse
    Push-Location $dnLock
    & dotnet restore Fixture.csproj -p:RestorePackagesWithLockFile=true -nologo *> $null
    $dnLocked = (($LASTEXITCODE -eq 0) -and (Test-Path (Join-Path $dnLock 'packages.lock.json')))
    Pop-Location
    if ($dnLocked) {
        [IO.File]::WriteAllText((Join-Path $dnLock 'Fixture.csproj'), $dnProjClean.Replace('</PropertyGroup>', @'
  <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
    <RestoreLockedMode>true</RestoreLockedMode>
  </PropertyGroup>
'@))
        $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnLock -All -Full 2>&1 | Out-String)
        $dnLockCode = $LASTEXITCODE
        Check 'a repository the analyzers cannot be injected into is still built' `
            (($dnLockCode -eq 0) -and ($out -match '\[PASS\] build')) "code=$dnLockCode $out"
        # Silently building without them would be worse than not injecting at all: the report
        # would claim an analysis nobody performed.
        Check 'a failed injection says so, with its reason' `
            (($out -match '\[WARN\] analyzers -- injection failed, built without them') -and ($out -match 'NU1004')) $out
    }
    else {
        Write-Output '[skip] no lock file could be produced -- the injection fallback cannot be exercised'
    }

    # templates/.editorconfig (#65): copying it into a repository must not turn the gate red --
    # every rule sits at `suggestion`, and no charset/end_of_line/final-newline setting that
    # the whitespace phase would fail on. A Harmony patch parameter is in the file on purpose.
    $dnEc = Join-Path $tmp 'dotnet-editorconfig'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnEc -Recurse
    Copy-Item (Join-Path $PSScriptRoot 'templates\.editorconfig') $dnEc
    [IO.File]::WriteAllText((Join-Path $dnEc 'Patch.cs'), $dnCsClean.Replace('class Greeter', 'class HudPatch').Replace(
            'Greet(string name)', 'Greet(string name, object __instance)'))
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnEc -All -Full 2>&1 | Out-String)
    $dnEcCode = $LASTEXITCODE
    Check 'the template .editorconfig keeps a clean project green at the full level' `
        (($dnEcCode -eq 0) -and ($out -match '\[PASS\] format') -and ($out -match '\[PASS\] build') -and ($out -notmatch 'IDE1006')) "code=$dnEcCode $out"
    # The other side: the template's rules are live, not a file nothing reads.
    Push-Location $dnEc
    $ecInfo = (& dotnet format style Fixture.csproj --verify-no-changes --no-restore --severity info 2>&1 | Out-String)
    Pop-Location
    Check 'the template .editorconfig rules fire at info severity, but not on __instance' `
        (($ecInfo -match 'IDE0022') -and ($ecInfo -notmatch 'IDE1006')) $ecInfo

    # `dotnet format style` (#66): a rule the repository raised to `warning` is reported at the
    # full level, advisory -- the template run above is the clean side (no code-style line).
    Check 'the template .editorconfig reports no code-style violation' ($out -notmatch 'code-style violation') $out
    $dnStyle = Join-Path $tmp 'dotnet-style'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnStyle -Recurse
    [IO.File]::WriteAllText((Join-Path $dnStyle '.editorconfig'), "root = true`r`n[*.cs]`r`ncsharp_style_expression_bodied_methods = true:warning`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnStyle -All -Full 2>&1 | Out-String)
    $dnStyleCode = $LASTEXITCODE
    Check 'a code-style violation is a full-level warning with its fix command' `
        (($dnStyleCode -eq 0) -and ($out -match '\[WARN\] Fixture\.csproj: 1 code-style violation\(s\) -- IDE0022 x1 \(fix: dotnet format style Fixture\.csproj\)')) "code=$dnStyleCode $out"
    $r = Invoke-Gate $dnStyle
    Check 'the fast lane does not pay for dotnet format style' ($r.Out -notmatch 'code-style') $r.Out

    # BannedApiAnalyzers (#63): a BannedSymbols.txt is the opt-in, and the package is injected
    # only from the machine's NuGet cache -- the gate never downloads it.
    $dnBan = Join-Path $tmp 'dotnet-banned'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnBan -Recurse
    [IO.File]::WriteAllText((Join-Path $dnBan 'BannedSymbols.txt'), "T:System.DateTime;Use game ticks`r`n")
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnBan -All -Full 2>&1 | Out-String)
    if ($out -match '\[SKIP\] Microsoft\.CodeAnalysis\.BannedApiAnalyzers') {
        Write-Output '[skip] BannedApiAnalyzers not in the local NuGet cache -- the injection checks cannot run'
    }
    else {
        Check 'a BannedSymbols.txt with no banned call stays silent' `
            (($LASTEXITCODE -eq 0) -and ($out -notmatch 'RS0030')) $out
        [IO.File]::WriteAllText((Join-Path $dnBan 'Greeter.cs'), $dnCsClean.Replace('return $"Hello, {name}!";', 'return $"Hello, {name}! {System.DateTime.Now.Ticks}";'))
        $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnBan -All -Full 2>&1 | Out-String)
        $dnBanCode = $LASTEXITCODE
        Check 'a banned API call is an analyzer warning, not a failure' `
            (($dnBanCode -eq 0) -and ($out -match 'analyzer diagnostic\(s\)[^\r\n]*RS0030') -and ($out -notmatch 'compiler warning')) "code=$dnBanCode $out"
    }
    # Not cached: said out loud, nothing fetched. An empty NUGET_PACKAGES is "a machine that
    # never restored it"; .qgate-no-analyzers keeps Meziantou from needing the network too.
    $nugetPrev = $env:NUGET_PACKAGES   # this machine may point it at another drive
    $dnBanEmpty = New-Item -ItemType Directory -Force (Join-Path $tmp 'nuget-empty')
    New-Item -ItemType File (Join-Path $dnBan '.qgate-no-analyzers') -Force | Out-Null
    $env:NUGET_PACKAGES = $dnBanEmpty.FullName
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnBan -All -Full 2>&1 | Out-String)
    $dnBanCode = $LASTEXITCODE
    $env:NUGET_PACKAGES = $nugetPrev
    Check 'an uncached BannedApiAnalyzers is a skip, not a download' `
        (($dnBanCode -eq 0) -and ($out -match '\[SKIP\] Microsoft\.CodeAnalysis\.BannedApiAnalyzers \(BannedSymbols\.txt\) -- not in the local NuGet cache') -and
            (-not (Get-ChildItem $dnBanEmpty.FullName))) "code=$dnBanCode $out"
    }

    if (Want 'dotnet3') {
    $nugetPrev = $env:NUGET_PACKAGES
    $dnBanEmpty = New-Item -ItemType Directory -Force (Join-Path $tmp 'nuget-empty')
    # SonarAnalyzer.CSharp (#62): qgate.json dotnet.sonar, same cache-only injection.
    $dnSonar = Join-Path $tmp 'dotnet-sonar'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnSonar -Recurse
    [IO.File]::WriteAllText((Join-Path $dnSonar 'Greeter.cs'), $dnCsClean.Replace('return $"Hello, {name}!";', 'string password = "hunter2secret"; return $"Hello, {name}!{password.Length}";'))
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnSonar -All -Full 2>&1 | Out-String)
    Check 'Sonar rules do not run without the qgate.json opt-in' ($out -notmatch 'S2068|SonarAnalyzer') $out
    '{"dotnet": {"sonar": true}}' | Set-Content (Join-Path $dnSonar 'qgate.json')
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnSonar -All -Full 2>&1 | Out-String)
    $dnSonarCode = $LASTEXITCODE
    if ($out -match '\[SKIP\] SonarAnalyzer\.CSharp') {
        Write-Output '[skip] SonarAnalyzer.CSharp not in the local NuGet cache -- the injection checks cannot run'
    }
    else {
        Check 'dotnet.sonar reports a hardcoded credential as an analyzer warning' `
            (($dnSonarCode -eq 0) -and ($out -match 'analyzer diagnostic\(s\)[^\r\n]*S2068')) "code=$dnSonarCode $out"
    }
    New-Item -ItemType File (Join-Path $dnSonar '.qgate-no-analyzers') -Force | Out-Null
    $env:NUGET_PACKAGES = $dnBanEmpty.FullName
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnSonar -All -Full 2>&1 | Out-String)
    $dnSonarCode = $LASTEXITCODE
    $env:NUGET_PACKAGES = $nugetPrev
    Check 'an uncached SonarAnalyzer.CSharp is a skip, not a download' `
        (($dnSonarCode -eq 0) -and ($out -match '\[SKIP\] SonarAnalyzer\.CSharp \(qgate\.json dotnet\.sonar\) -- not in the local NuGet cache')) "code=$dnSonarCode $out"

    # JetBrains InspectCode (#64): qgate.json dotnet.inspectcode, advisory, jb absent = skip.
    $dnIc = Join-Path $tmp 'dotnet-inspectcode'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnIc -Recurse
    '{"dotnet": {"inspectcode": true}}' | Set-Content (Join-Path $dnIc 'qgate.json')
    $icPath = $env:PATH
    $env:PATH = (@($env:PATH -split [IO.Path]::PathSeparator | Where-Object { $_ -and -not (Test-Path (Join-Path $_ 'jb.exe')) -and -not (Test-Path (Join-Path $_ 'jb')) }) -join [IO.Path]::PathSeparator)
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnIc -All -Full 2>&1 | Out-String)
    $dnIcCode = $LASTEXITCODE
    $env:PATH = $icPath
    Check 'dotnet.inspectcode without jb on PATH is a skip' `
        (($dnIcCode -eq 0) -and ($out -match '\[SKIP\] inspectcode -- jb not on PATH')) "code=$dnIcCode $out"
    if (Get-Command jb -ErrorAction SilentlyContinue) {
        $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnIc -All -Full 2>&1 | Out-String)
        Check 'InspectCode passes a clean project' (($LASTEXITCODE -eq 0) -and ($out -match '\[PASS\] inspectcode Fixture\.csproj')) $out
        [IO.File]::WriteAllText((Join-Path $dnIc 'Greeter.cs'), $dnCsClean.Replace('    public static string Greet(string name)', @'
    private static int Unused(int a)
    {
        return a;
    }

    public static bool Prefix(object __instance)
    {
        return __instance is null;
    }

    public static string Greet(string name)
'@))
        $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnIc -All -Full 2>&1 | Out-String)
        $dnIcCode = $LASTEXITCODE
        Check 'InspectCode findings are warnings with their location' `
            (($dnIcCode -eq 0) -and ($out -match 'InspectCode finding\(s\)') -and
                ($out -match '\[WARN\] inspectcode: Greeter\.cs:\d+ UnusedMember\.Local')) "code=$dnIcCode $out"
        Check 'InspectCode does not ask to rename a Harmony __instance parameter' ($out -notmatch "InconsistentNaming[^\r\n]*__instance") $out
    }
    else { Write-Output '[skip] jb (JetBrains.ReSharper.GlobalTools) not on PATH -- InspectCode checks cannot run' }

    # BepInEx metadata (#67): only where BepInEx is referenced, advisory, source-level. The
    # reference points at a game this machine does not have -- the check still runs.
    $dnBep = Join-Path $tmp 'dotnet-bepinex'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\dotnet-fixture') $dnBep -Recurse
    [IO.File]::WriteAllText((Join-Path $dnBep 'Plugins.cs'), @'
namespace Fixture;

[BepInEx.BepInPlugin(Good.Guid, "Good", Good.Version)]
[BepInEx.BepInDependency("com.bepis.configmanager")]
public sealed class Good
{
    public const string Guid = "morgott.valheim.good";

    public const string Version = "1.3.0";
}

[BepInEx.BepInPlugin("Bad Guid", "Bad", "1.0.0-beta")]
[BepInEx.BepInDependency("")]
public sealed class Bad
{
}
'@)
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnBep -All -Full 2>&1 | Out-String)
    Check 'BepInEx metadata is not checked in a project that does not reference BepInEx' ($out -notmatch 'bepinex:') $out
    [IO.File]::WriteAllText((Join-Path $dnBep 'Fixture.csproj'), $dnProjClean.Replace('</Project>', @'
  <ItemGroup>
    <Reference Include="BepInEx">
      <HintPath>..\game\BepInEx.dll</HintPath>
    </Reference>
  </ItemGroup>

</Project>
'@))
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $dnBep -All -Full 2>&1 | Out-String)
    $dnBepCode = $LASTEXITCODE
    Check 'malformed BepInEx GUIDs and versions are warnings' `
        (($dnBepCode -eq 0) -and ($out -match "\[WARN\] bepinex: BepInPlugin GUID 'Bad Guid' is not reverse-DNS \(e\.g\. com\.author\.mod\) \(Plugins\.cs:12\)") -and
            ($out -match "\[WARN\] bepinex: BepInPlugin version '1\.0\.0-beta' -- valid SemVer, but BepInEx 5") -and
            ($out -match '\[WARN\] bepinex: BepInDependency GUID is empty \(Plugins\.cs:13\)')) "code=$dnBepCode $out"
    Check 'valid BepInEx metadata (literal or const) stays silent' `
        (@([regex]::Matches($out, '\[WARN\] bepinex:')).Count -eq 3) $out

    # Harmony patch targets (gate/harmony.ps1). A mod whose HintPaths point at a "game" in
    # ..\lib: first with the game absent -- the existing SKIP, and no harmony phase -- then
    # with it built, where two valid patches must stay silent and four dangling ones must not.
    $hm = Join-Path $tmp 'harmony'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\harmony-fixture') $hm -Recurse
    $hmMod = Join-Path $hm 'Mod'
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $hmMod -All -Full 2>&1 | Out-String)
    Check 'a Harmony mod without its game is a skip, not a harmony verdict' `
        (($LASTEXITCODE -eq 0) -and ($out -match 'game/SDK not installed') -and ($out -notmatch '\] harmony')) $out
    foreach ($p in 'Game', 'Harmony') { & dotnet build (Join-Path $hm $p) -o (Join-Path $hm 'lib') -nologo -v q *> $null }
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $hmMod -All -Full 2>&1 | Out-String)
    $hmCode = $LASTEXITCODE
    Check 'dangling Harmony targets fail the harmony phase' `
        (($hmCode -ne 0) -and ($out -match '\[PASS\] build') -and ($out -match '\[FAIL\] harmony')) "code=$hmCode $out"
    Check 'each dangling target is named with its source location' `
        (($out -match 'Hud\.UpdateStatusEffects not found \(Patches\.cs:\d+, StatusPatch\.Postfix\)') -and
            ($out -match 'field m_stamina not found \(parameter ___m_stamina\)') -and
            ($out -match "Hud\.UpdateHealth has no parameter 'delta'") -and
            ($out -match 'Hud\.UpdateFood method not found \(AccessTools\.Method\)')) $out
    Check 'argumentTypes right in number but wrong in type fail' `
        (($out -match 'Hud\.Damage\(Unit, System\.String\) not found; have \(Unit, System\.Single\)') -and
            ($out -match 'Hud\.Damage\(System\.String, System\.Single\) method not found \(AccessTools\.Method\)')) $out
    Check 'argumentTypes wrong in number fail (a target that gained a parameter)' `
        ($out -match 'Hud\.Damage\(Unit\) not found; have \(Unit, System\.Single\)') $out
    Check 'Type.GetMethod, "Type:Method" and TypeByName lookups are checked' `
        (($out -match 'Hud\.UpdateArmor method not found \(Type\.GetMethod\)') -and
            ($out -match 'Hud\.UpdateStamina method not found \(AccessTools\.Method\)') -and
            ($out -match 'type Minimap not found \(AccessTools\.TypeByName\)')) $out
    Check 'a null-checked lookup is a version probe: a warning, not a failure' `
        (($out -match '\[WARN\] harmony: Hud\.UpdateShield .*null-checked') -and
            ($out -match '\[WARN\] harmony: Hud\.UpdateMana .*null-checked') -and
            ($out -notmatch '(?m)^(?!\[WARN\]).*Hud\.Update(Shield|Mana)')) $out
    Check 'lookups that cannot be checked statically are counted' `
        ($out -match '\[NOTE\] harmony: Mod\.dll -- \d+ target\(s\) checked, 2 not checkable statically') $out
    Check 'valid Harmony targets stay silent (assignable, interface, generic argumentTypes too)' `
        (($out -notmatch 'HealthPatch|HealthGetterPatch|AssignablePatch|m_health|Lookups\.Valid')) $out
    # -Why names every target that resolved: a new patch is confirmed by name, not by a count.
    $outWhy = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $hmMod -All -Full -Why 2>&1 | Out-String)
    Check '-Why lists each resolved Harmony target by name' `
        (($outWhy -match '\[NOTE\] harmony: OK \S*Hud\.UpdateHealth \(Patches\.cs:\d+, HealthPatch\.Postfix\)') -and
            ($out -notmatch '\[NOTE\] harmony: OK ')) $outWhy
    # Other assemblies (qgate.json harmony.assemblies): the same checks, reported as warnings.
    $plug = New-Item -ItemType Directory -Force (Join-Path $hm 'plugins')
    Copy-Item (Get-ChildItem (Join-Path $hmMod 'bin') -Recurse -Filter Mod.dll | Select-Object -First 1).FullName (Join-Path $plug 'Other.dll')
    '{"harmony": {"assemblies": ["../plugins/**/*.dll"]}}' | Set-Content (Join-Path $hmMod 'qgate.json')
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $hmMod -All -Full 2>&1 | Out-String)
    Check 'qgate.json harmony.assemblies are checked too, as warnings' `
        (($out -match '\[WARN\] harmony: Other\.dll: Hud\.UpdateFood method not found') -and
            ($out -match '\[NOTE\] harmony: Other\.dll -- ')) $out
    }
} else {
    Write-Output '[skip] no .NET SDK on this machine -- the dotnet stack cannot be exercised'
}

}

if (Want 'proto') {
# 16. Proto, red then green. buf ships with nothing else, so its absence is a
# skip -- same rule as golangci-lint above.
if (Get-Command buf -ErrorAction SilentlyContinue) {
    $proto = Join-Path $tmp 'proto'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') $proto -Recurse
    $r = Invoke-Gate $proto
    Check 'clean proto fixture passes' ($r.Code -eq 0) $r.Out
    $pf = Join-Path $proto 'example\v1\greeting.proto'
    $pClean = [IO.File]::ReadAllText($pf)
    [IO.File]::WriteAllText($pf, $pClean.Replace('string text = 1;', 'string Text = 1;'))
    $r = Invoke-Gate $proto
    Check 'proto lint violation fails the gate' (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] buf lint')) $r.Out
    [IO.File]::WriteAllText($pf, $pClean)
    $r = Invoke-Gate $proto
    Check 'proto green again after the fix' ($r.Code -eq 0) $r.Out
} else {
    Write-Output '[skip] buf not on PATH'
}

}

if (Want 'godot') {
# 17. Godot. The binary is usually absent on Windows, which is exactly when a
# naive gate goes quiet -- so the phases that need no binary are checked for real
# here, and the missing binary itself has to be a loud failure.
$gdt = Join-Path $tmp 'godot'
Copy-Item (Join-Path $PSScriptRoot 'testdata\godot-fixture') $gdt -Recurse
$gdMain = Join-Path $gdt 'main.gd'
$gdClean = [IO.File]::ReadAllText($gdMain)
[IO.File]::WriteAllText($gdMain, "extends Node`n`nconst MISSING := preload(`"res://does_not_exist.gd`")`n")
$r = Invoke-Gate $gdt
Check 'dangling res:// reference fails the gate' `
    (($r.Code -ne 0) -and ($r.Out -match 'res://does_not_exist\.gd does not resolve')) $r.Out
# The one Windows cannot catch by asking the filesystem: right file, wrong case.
# It loads here and breaks in a Linux CI run or export.
[IO.File]::WriteAllText($gdMain, "extends Node`n`nconst S := preload(`"res://Main.gd`")`n")
$r = Invoke-Gate $gdt
Check 'wrong-case res:// reference fails the gate' `
    (($r.Code -ne 0) -and ($r.Out -match 'res://Main\.gd does not resolve')) $r.Out
[IO.File]::WriteAllText($gdMain, $gdClean)
# A uid:// cannot be checked against a path -- only against the file that declares
# it -- and Godot rewrites paths by uid, so a stale one silently loads nothing.
$gdScene = Join-Path $gdt 'main.tscn'
$scClean = [IO.File]::ReadAllText($gdScene)
[IO.File]::WriteAllText($gdScene, $scClean.Replace('[ext_resource type="Script"', '[ext_resource type="Script" uid="uid://cnotdeclared"'))
$r = Invoke-Gate $gdt
Check 'dangling uid:// reference fails the gate' `
    (($r.Code -ne 0) -and ($r.Out -match 'main\.tscn:\d+: uid://cnotdeclared matches nothing')) $r.Out
# Godot 4.4+ declares a script's uid in a `.gd.uid` sidecar, not in any .tscn/.import.
[IO.File]::WriteAllText("$gdMain.uid", "uid://cnotdeclared`n")
$r = Invoke-Gate $gdt
Check 'uid:// declared by a .gd.uid sidecar resolves' ($r.Out -notmatch 'matches nothing') $r.Out
Remove-Item "$gdMain.uid"
[IO.File]::WriteAllText($gdScene, $scClean)
$r = Invoke-Gate $gdt
Check 'res:// scan clean once the reference is fixed' (($r.Out -notmatch 'does not resolve') -and ($r.Out -notmatch 'matches nothing')) $r.Out
if (Get-GodotBin) {
    Check 'godot fixture passes with a real binary' ($r.Code -eq 0) $r.Out
} else {
    Write-Output '[skip] GODOT_BIN unset -- import/test/smoke phases not exercised'
}
# The missing binary is fatal at the full level and a warning in the fast lane:
# every phase that needs it is full-level only, so failing the fast lane over it
# blocked every agent turn on a binary the turn was never going to invoke. Run
# both levels with GODOT_BIN cleared, whether or not this machine has one.
if (-not (Get-Command godot -ErrorAction SilentlyContinue)) {
    $priorGodot = $env:GODOT_BIN
    $env:GODOT_BIN = $null
    try {
        $fastOut = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $gdt -All 2>&1 | Out-String)
        $fastCode = $LASTEXITCODE
        $fullOut = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $gdt -All -Full 2>&1 | Out-String)
        $fullCode = $LASTEXITCODE
    } finally { $env:GODOT_BIN = $priorGodot }
    Check 'no GODOT_BIN does not fail the fast lane' ($fastCode -eq 0) $fastOut
    Check 'no GODOT_BIN is still said out loud in the fast lane' ($fastOut -match 'GODOT_BIN') $fastOut
    Check 'no GODOT_BIN fails the full level' (($fullCode -ne 0) -and ($fullOut -match 'set GODOT_BIN')) $fullOut
} else {
    Write-Output '[skip] godot is on PATH -- the missing-binary levels cannot be exercised'
}

}

if (Want 'core') {
# 12. A directory that is not a git repository must not pass by way of "no
# changes": the default run has nothing to narrow by and has to check everything.
$nogit = Join-Path $tmp 'nogit'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $nogit -Recurse
Set-GoFile (Join-Path $nogit 'broken.go') "package main`nfunc  Broken() {}"
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $nogit 2>&1 | Out-String)
Check 'non-git directory is checked, not skipped' (($LASTEXITCODE -ne 0) -and ($out -notmatch 'no changes')) $out

}

if (Want 'wiring') {
# 13. The wiring templates must call the entry point that actually exists. The
# lefthook job pointed at a path `wire` no longer creates, which broke every
# commit in a repo that had lefthook.
# It must also call qgate.cmd, not bare qgate: lefthook runs jobs through Git Bash,
# where PATHEXT does not apply and a bare `qgate` exits 127, command not found.
$lh = Get-Content (Join-Path $PSScriptRoot 'templates\lefthook.yml') -Raw
Check 'lefthook template calls qgate.cmd' (($lh -match 'run:.*qgate\.cmd ') -and ($lh -notmatch 'tools/quality-gate')) $lh
# A commit in an agent workflow is a tool call, so the hook's stdout is context the
# model pays for -- measured at 342 chars of [PASS] lines per commit on a
# three-stack monorepo. Silent on green, loud on red. CI keeps its output, which is
# why this is a property of the generated hooks and not a global default.
$hookTpl = Get-Content (Join-Path $PSScriptRoot 'templates\pre-commit') -Raw
$invocations = @([regex]::Matches("$lh`n$hookTpl", '(?m)^(?!\s*#).*qgate(\.cmd)? -All -Full.*$') |
    ForEach-Object { $_.Value })
$noisy = @($invocations | Where-Object { $_ -notmatch '-Quiet' })
Check 'every generated pre-commit invocation is quiet on green' `
    (($invocations.Count -ge 3) -and ($noisy.Count -eq 0)) `
    "found $($invocations.Count), noisy: $($noisy -join ' | ')"

# 13b (#80). Wire ends by running the gate once: on a red repository it says so and
# names the adoption path instead of "break something on purpose", and wiring still
# exits 0. Base-stack-only fixtures, so each run costs ~2-5s, not a Go build.
$greenWire = Join-Path $tmp 'wire-green'
New-Item -ItemType Directory -Path $greenWire -Force | Out-Null
git -C $greenWire init -q 2>$null
Set-Content (Join-Path $greenWire 'notes.md') 'the word'
$gOut = (& pwsh -NoProfile -File $installer -Target $greenWire -NoHook 2>&1 | Out-String)
Check 'wire on a green repo prints GREEN and the break-something hint' `
    (($LASTEXITCODE -eq 0) -and ($gOut -match 'GREEN') -and ($gOut -match 'break something on purpose')) $gOut
if (Get-Command typos -ErrorAction SilentlyContinue) {
    $redWire = Join-Path $tmp 'wire-red'
    New-Item -ItemType Directory -Path $redWire -Force | Out-Null
    git -C $redWire init -q 2>$null
    Set-Content (Join-Path $redWire 'notes.md') 'teh word'
    $rOut = (& pwsh -NoProfile -File $installer -Target $redWire -NoHook 2>&1 | Out-String)
    Check 'wire on a red repo prints RED, the adoption path, no break-something hint, exit 0' `
        (($LASTEXITCODE -eq 0) -and ($rOut -match 'RED') -and ($rOut -match '\[FAIL\] typos') -and
         ($rOut -match '-Baseline') -and ($rOut -match '_typos\.toml') -and ($rOut -notmatch 'break something')) $rOut
} else {
    Write-Output '[skip] no typos -- wire red-verdict fixture needs a failing base phase'
}

# 14. gofmt reads a CRLF checkout as unformatted, so the .gitattributes line is a
# prerequisite, not advice -- wire has to write it. Go repo: it is a Go rule.
$goWire = Join-Path $tmp 'gowire'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $goWire -Recurse
git -C $goWire init -q 2>$null
& pwsh -NoProfile -File $installer -Target $goWire -NoRun -NoHook *> $null
$ga = Join-Path $goWire '.gitattributes'
Check 'wire writes the gofmt eol rule' ((Test-Path $ga) -and ((Get-Content $ga -Raw) -match '\*\.go text eol=lf')) `
    "$(if (Test-Path $ga) { Get-Content $ga -Raw })"
# The rule governs only what git writes NEXT: files already on disk stay CRLF and
# gofmt fails on every one of them. Wire printed "fixed" and said nothing about that,
# so the first run after wire failed 57 files with no hint. Assert the count and the
# command -- "printed something" is what let the silence through in the first place.
# The command must be gofmt -w: `git add --renormalize . && git checkout -- .` is the
# answer everyone reaches for and it is a no-op, because --renormalize leaves the
# index stat cache matching the CRLF file and checkout then skips it. Asserting its
# absence is what stops that from being "helpfully" restored later.
[IO.File]::WriteAllText((Join-Path $goWire 'crlf.go'), "package main`r`n")
git -C $goWire add -A 2>$null
$wireOut = (& pwsh -NoProfile -File $installer -Target $goWire -NoRun -NoHook 2>&1 | Out-String)
Check 'wire names a command that really rewrites a CRLF working tree' `
    (($wireOut -match '1 tracked \.go file\(s\) are CRLF') -and ($wireOut -match '(?m)^\s+gofmt -w \.\s*$')) $wireOut
Check 'wire does not name the renormalise no-op' ($wireOut -notmatch 'renormalize') $wireOut

# `qgate wire` is run again every time the gate is upgraded, so a second run with
# nothing to change must be a no-op. Set-Content appends its own newline on top of the
# one the body already ends with, so every rewrite left one more blank line at the end
# of the file than it found; and the comparison was made against raw bytes, so a file
# git had checked out as CRLF -- which `* text=auto` does to every doc in a repo with
# core.autocrlf=true -- never equalled the LF block and was rewritten every run.
$agentsFile = Join-Path $goWire 'AGENTS.md'
$agentsBefore = [IO.File]::ReadAllBytes($agentsFile)
$wireAgain = (& pwsh -NoProfile -File $installer -Target $goWire -NoRun -NoHook 2>&1 | Out-String)
$agentsAfter = [IO.File]::ReadAllBytes($agentsFile)
Check 'a second wire leaves AGENTS.md byte-identical' `
    ((($agentsBefore -join ',') -eq ($agentsAfter -join ',')) -and ($wireAgain -match 'AGENTS\.md\s+-- unchanged')) `
    "before=$($agentsBefore.Length) after=$($agentsAfter.Length)"
# ...and it is not enough that the size stopped moving: the file must not carry the
# blank line the old write left behind, or every wired repo keeps one forever.
Check 'the wired doc ends with exactly one newline' `
    (($agentsAfter[-1] -eq 10) -and ($agentsAfter[-2] -ne 10)) `
    ("tail=" + [BitConverter]::ToString($agentsAfter[-4..-1]))

# #85: AGENTS.md tracked as a git symlink to CLAUDE.md, checked out with
# core.symlinks=false as a plain file holding the target path. Wire must leave it alone
# (writing the block broke the link on every other platform) and still wire CLAUDE.md.
$linkRepo = Join-Path $tmp 'wire-symlink'
New-Item -ItemType Directory -Path $linkRepo | Out-Null
git -C $linkRepo init -q 2>$null
git -C $linkRepo config core.symlinks false
Set-Content (Join-Path $linkRepo 'CLAUDE.md') '# project'
$blob = ('CLAUDE.md' | git -C $linkRepo hash-object -w --stdin)
git -C $linkRepo update-index --add --cacheinfo "120000,$blob,AGENTS.md"
git -C $linkRepo checkout -- AGENTS.md 2>$null
$linkOut = (& pwsh -NoProfile -File $installer -Target $linkRepo -NoRun -NoHook 2>&1 | Out-String)
Check 'wire leaves a symlinked AGENTS.md untouched' `
    (([IO.File]::ReadAllText((Join-Path $linkRepo 'AGENTS.md')).Trim() -eq 'CLAUDE.md') -and
     ($linkOut -match 'AGENTS\.md\s+-- symlink to CLAUDE\.md')) $linkOut
Check 'wire still writes the block into the symlink target' `
    ((Get-Content (Join-Path $linkRepo 'CLAUDE.md') -Raw) -match '<!-- quality-gate -->') $linkOut

# A lefthook.yml this installer wrote at an OLDER version is not a foreign file, but
# "kept existing lefthook.yml" said the same thing about both. When pre-merge-commit
# was added to the template, every already-wired repo kept its pre-commit-only config
# and `qgate wire` reported success while the merge bypass stayed wide open -- the
# upgrade was undeliverable by the very command that announces it.
if (Get-Command lefthook -ErrorAction SilentlyContinue) {
    $lhr = Join-Path $tmp 'lefthookver'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $lhr -Recurse
    git -C $lhr init -q 2>$null
    & pwsh -NoProfile -File $installer -Target $lhr -NoRun *> $null
    $curOut = (& pwsh -NoProfile -File $installer -Target $lhr -NoRun 2>&1 | Out-String)
    # The absence half, and it is falsifiable here because this repo really was wired
    # by this version a line ago: a check that fires on a current config would make the
    # warning noise nobody reads.
    Check 'a current lefthook.yml is not reported as stale' ($curOut -notmatch 'no pre-merge-commit hook') $curOut
    Set-Content (Join-Path $lhr 'lefthook.yml') "pre-commit:`n  jobs:`n    - name: quality-gate`n      run: 'qgate.cmd -All -Full -Quiet'`n"
    $staleOut = (& pwsh -NoProfile -File $installer -Target $lhr -NoRun 2>&1 | Out-String)
    Check 'wire names the hook a stale lefthook.yml is missing' `
        (($staleOut -match 'no pre-merge-commit hook') -and ($staleOut -match 'lefthook install')) $staleOut
} else {
    Write-Output '[skip] lefthook not on PATH -- the stale-config path cannot run'
}

}

if (Want 'go2') {
# go2 is its own job in a parallel run: rebuild what the go part leaves behind -- the clean
# fixture with the template config, and whether a -Full run is green on this machine.
if ($null -eq $fullGreen) {
    $go = Join-Path $tmp 'go'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $go -Recurse
    Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $go
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $go -All -Full *> $null
    $fullGreen = ($LASTEXITCODE -eq 0)
}
# 15. The version report is advisory. It must never fail a run -- offline, rate
# limited or with a registry that answers garbage, the exit code stays 0.
$outdated = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $go 2>&1 | Out-String)
Check 'outdated never fails the run' ($LASTEXITCODE -eq 0) $outdated

}

if (Want 'hooks') {
# 12. The agent contract: `qgate stop-hook` must reach Claude Code as exit code 2
# with the reason on stderr, through the .cmd shim it is actually invoked by.
# Anything less and a failing gate silently lets the agent declare victory.
$hookRepo = Join-Path $tmp 'hook'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $hookRepo -Recurse
git -C $hookRepo init -q 2>$null
git -C $hookRepo add -A 2>$null   # silences the CRLF-conversion warnings
git -C $hookRepo -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
# -Fast only looks at changed files, so the violation has to be uncommitted.
Set-GoFile (Join-Path $hookRepo 'bad.go') "package main`nfunc  Bad() {}"
Push-Location $hookRepo
try {
    $stderrFile = Join-Path $tmp 'hook.err'
    $env:CLAUDE_PROJECT_DIR = $hookRepo
    # A fresh session id every run: the block counter lives in TEMP keyed by
    # (repo, session) and a leftover from an earlier run would make the gate give
    # up on the first block instead of blocking.
    $hookOut = "{`"session_id`":`"$([guid]::NewGuid())`"}" |
        & cmd /c "`"$(Join-Path $PSScriptRoot 'bin\qgate.cmd')`" stop-hook" 2>$stderrFile
    $hookCode = $LASTEXITCODE
    $env:CLAUDE_PROJECT_DIR = $null
} finally { Pop-Location }
$hookErr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { '' }
Check 'stop-hook blocks the turn with exit 2' ($hookCode -eq 2) "code=$hookCode"
Check 'stop-hook puts the reason on stderr' ($hookErr -match 'Quality gate failed') $hookErr
Check 'stop-hook keeps stdout clean' ([string]::IsNullOrWhiteSpace(($hookOut | Out-String))) ($hookOut | Out-String)

# 12b (#77). Claude Code on Windows runs command hooks through Git Bash, which has
# no PATHEXT: the wired `qgate stop-hook` died with exit 127 (non-blocking) and the
# gate never ran. Run the command wire actually writes, through Git's bash.exe.
# A rewire over an existing settings.json must keep the user's hook and not
# duplicate ours.
$swRepo = Join-Path $tmp 'stopwire'
New-Item -ItemType Directory -Path (Join-Path $swRepo '.claude') -Force | Out-Null
git -C $swRepo init -q 2>$null
$swFile = Join-Path $swRepo '.claude\settings.json'
Set-Content $swFile '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]},{"hooks":[{"type":"command","command":"qgate stop-hook"}]}]}}'
& pwsh -NoProfile -File $installer -Target $swRepo -NoRun -NoHook *> $null
& pwsh -NoProfile -File $installer -Target $swRepo -NoRun -NoHook *> $null
$swCmds = @((Get-Content $swFile -Raw | ConvertFrom-Json).hooks.Stop.hooks.command)
Check 'wire keeps other Stop hooks and never duplicates its own' `
    ((@($swCmds | Where-Object { $_ -eq 'echo mine' }).Count -eq 1) -and (@($swCmds | Where-Object { $_ -match 'qgate' }).Count -eq 1)) ($swCmds -join ' | ')
# Opt-out: qgate.json {"stopHook": false} removes only our entry -- including one
# sharing a group with the user's hook -- and a rewire does not add it back.
$soRepo = Join-Path $tmp 'stopoptout'
New-Item -ItemType Directory -Path (Join-Path $soRepo '.claude') -Force | Out-Null
git -C $soRepo init -q 2>$null
$soFile = Join-Path $soRepo '.claude\settings.json'
Set-Content $soFile '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo pre"}]}],"Stop":[{"hooks":[{"type":"command","command":"echo mine"},{"type":"command","command":"qgate stop-hook"}]},{"hooks":[{"type":"command","command":"qgate stop-hook"}]}]}}'
Set-Content (Join-Path $soRepo 'qgate.json') '{"stopHook": false}'
& pwsh -NoProfile -File $installer -Target $soRepo -NoRun -NoHook *> $null
& pwsh -NoProfile -File $installer -Target $soRepo -NoRun -NoHook *> $null
$soJson = Get-Content $soFile -Raw | ConvertFrom-Json
$soCmds = @($soJson.hooks.Stop.hooks.command)
Check 'stopHook: false removes our Stop hook, keeps the user''s hooks, and stays off on rewire' `
    (($soCmds -join '|') -eq 'echo mine' -and (@($soJson.hooks.PreToolUse.hooks.command) -join '|') -eq 'echo pre') ($soJson | ConvertTo-Json -Depth 10)
$gitRoot = Split-Path (Split-Path (Split-Path (Split-Path (& git --exec-path))))
$bashExe = @((Join-Path $gitRoot 'bin\bash.exe'), (Get-Command bash -ErrorAction SilentlyContinue).Source) |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($bashExe) {
    $wiredCmd = @($swCmds | Where-Object { $_ -match 'qgate' })[0]
    $oldPath = $env:PATH
    Push-Location $hookRepo
    try {
        $env:PATH = "$(Join-Path $PSScriptRoot 'bin');$oldPath"
        $env:CLAUDE_PROJECT_DIR = $hookRepo
        $bashErr = Join-Path $tmp 'hook-bash.err'
        "{`"session_id`":`"$([guid]::NewGuid())`"}" | & $bashExe -c $wiredCmd 2>$bashErr | Out-Null
        $bashCode = $LASTEXITCODE
    } finally { $env:PATH = $oldPath; $env:CLAUDE_PROJECT_DIR = $null; Pop-Location }
    Check 'the wired Stop hook blocks with exit 2 under Git Bash' ($bashCode -eq 2) "code=$bashCode $bashExe $(Get-Content $bashErr -Raw)"
} else {
    Write-Output '[skip] no bash.exe -- the wired Stop hook cannot be run as Claude Code would'
}

# 22. The hook's blind spot: the fast level only ever looks at UNCOMMITTED work, so
# a turn that edits and commits leaves a clean tree and the hook waved it through --
# and every later turn too, because the commit never becomes uncommitted again. The
# hook now remembers the commit it was last green on. Two runs, because the first
# one is what records the mark; a single run would pass on the first-run rule and
# prove nothing about the case that matters.
$hook2 = Join-Path $tmp 'hook2'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $hook2 -Recurse
git -C $hook2 init -q 2>$null
git -C $hook2 add -A 2>$null
git -C $hook2 -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
function Invoke-StopHook([string]$Repo, [string]$Session) {
    $err = Join-Path $tmp "hook-$([guid]::NewGuid()).err"
    Push-Location $Repo
    try {
        $env:CLAUDE_PROJECT_DIR = $Repo
        "{`"session_id`":`"$Session`"}" | & cmd /c "`"$(Join-Path $PSScriptRoot 'bin\qgate.cmd')`" stop-hook" 2>$err | Out-Null
        $code = $LASTEXITCODE
        $env:CLAUDE_PROJECT_DIR = $null
    } finally { Pop-Location }
    $text = if (Test-Path $err) { Get-Content $err -Raw } else { '' }
    [pscustomobject]@{ Code = $code; Err = $text }
}
$sid = [guid]::NewGuid()
$h = Invoke-StopHook $hook2 $sid
Check 'stop-hook passes a clean repo and records it' ($h.Code -eq 0) "code=$($h.Code) $($h.Err)"
# Commit the violation, leave the tree clean: the state the old hook could not see.
Set-GoFile (Join-Path $hook2 'bad.go') "package main`nfunc  Bad() {}"
git -C $hook2 add -A 2>$null
git -C $hook2 -c user.email=selftest@local -c user.name=selftest commit -qm violation 2>$null
$h = Invoke-StopHook $hook2 $sid
Check 'stop-hook blocks a violation that was committed on a clean tree' ($h.Code -eq 2) "code=$($h.Code) $($h.Err)"

}

if (Want 'godot') {
# 18. `-All` is documented as "every detected stack, ignore git status", but the
# .gd list was still narrowed by git status under it: a tree whose dirty files are
# not .gd dropped gdformat and gdlint from the run and still printed [PASS] godot,
# with no SKIP and no WARN to say so. A phase that did not run must never be
# indistinguishable from a phase that passed.
if ((Get-Command gdformat -ErrorAction SilentlyContinue) -and (Get-Command gdlint -ErrorAction SilentlyContinue)) {
    git -C $gdt init -q 2>$null
    git -C $gdt add -A 2>$null
    git -C $gdt -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    [IO.File]::WriteAllText((Join-Path $gdt 'notes.txt'), "dirty, and not a .gd file`n")
    $r = Invoke-Gate $gdt
    Check '-All lints .gd even when git reports no .gd change' ($r.Out -match 'gdformat') $r.Out
    # The fast lane still narrows -- but says so out loud.
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $gdt 2>&1 | Out-String)
    Check 'a skipped gd lint phase is visible, not silent' ($out -match '\[SKIP\] gdformat/gdlint') $out
} else {
    Write-Output '[skip] gdtoolkit not on PATH'
}

}

if (Want 'go2') {
# 19. Discoverability: a flag value nobody validates and a config key nobody reads
# are both silent no-ops that look exactly like enforcement.
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $go -Only 'nonsense' 2>&1 | Out-String)
$onlyCode = $LASTEXITCODE
Check '-Only naming an undetected stack is reported' ($out -match '\[FAIL\] -Only nonsense') $out
# The half that was missing: a warning in a run that exits 0 is a green pipeline.
Check '-Only naming an undetected stack fails the run' ($onlyCode -ne 0) "code=$onlyCode $out"
# A real stack name must still work, or the validation would be worse than the bug.
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $go -Only 'go' 2>&1 | Out-String)
Check '-Only naming a detected stack still runs it' (($LASTEXITCODE -eq 0) -and ($out -match '\[PASS\] go')) $out
[IO.File]::WriteAllText((Join-Path $go 'qgate.json'), '{"tools": {"nosuchtool": "1.0.0"}}')
$r = Invoke-Gate $go
Check 'qgate.json pinning an unknown tool warns' ($r.Out -match "pins unknown tool 'nosuchtool'") $r.Out
if (Get-Command gdformat -ErrorAction SilentlyContinue) {
    [IO.File]::WriteAllText((Join-Path $go 'qgate.json'), '{"tools": {"gdtoolkit": "0.0.1"}}')
    $r = Invoke-Gate $go
    Check 'qgate.json can pin gdtoolkit' ($r.Out -match 'gdtoolkit .* qgate\.json pins 0\.0\.1') $r.Out
}
Remove-Item (Join-Path $go 'qgate.json')

}

if (Want 'core') {
# 20. Which stacks were selected, and the reason the gate gives for it. Both bugs
# here were invisible to a suite that asserts on stacks and phases: the run still
# checked something and still exited 0, it just said something untrue about why.
$sel = Join-Path $tmp 'select'
New-Item -ItemType Directory -Path $sel | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') (Join-Path $sel 'schema') -Recurse
git -C $sel init -q 2>$null
git -C $sel add -A 2>$null
git -C $sel -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
# Get-ChangedPaths documents $null as "not a git repository" and an empty list as
# "no changes". PowerShell enumerates a collection on return, so the empty list came
# back as $null: the [SKIP] no changes branch was unreachable, every clean-tree fast
# lane checked every stack, and it blamed git for it.
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $sel 2>&1 | Out-String)
$selCode = $LASTEXITCODE
Check 'a clean tree reports no changes' (($selCode -eq 0) -and ($out -match 'no changes')) "code=$selCode $out"
Check 'a clean git tree is not called a non-git directory' ($out -notmatch 'not a git repository') $out
# A root-level file belongs to no stack, so everything runs -- but the reason the
# gate printed was 'proto changed', with no .proto in the change set.
[IO.File]::WriteAllText((Join-Path $sel 'README.md'), "a root file, owned by no stack`n")
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $sel 2>&1 | Out-String)
Check 'a path outside every stack gives the reason that applied' ($out -match 'README\.md belongs to no stack') $out
Check 'a path outside every stack is not blamed on proto' ($out -notmatch 'proto changed') $out
# ...and the proto rule itself must still fire when a .proto really did change.
Remove-Item (Join-Path $sel 'README.md')
$pf = Join-Path $sel 'schema\example\v1\greeting.proto'
[IO.File]::WriteAllText($pf, ([IO.File]::ReadAllText($pf) -replace '(?m)^(syntax)', "// touched by the self-test`n`$1"))
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $sel 2>&1 | Out-String)
Check 'a real .proto change still widens with the proto reason' ($out -match 'proto changed') $out

# 21. Narrowing for a TRACKED edit. `git diff --name-only -z HEAD` goes through
# Out-String, which appends a trailing newline, so the split produced one "`r`n"
# element; it is non-empty and survived a filter placed before the trim, then the
# trim made it ''. That empty path sorted first, matched no stack, and widened the
# run on the first iteration -- so the fast lane had never narrowed for a tracked
# edit, and blamed proto for it. Every earlier check here used untracked fixtures,
# which is exactly why none of them saw it.
git -C $sel checkout -- . 2>$null
$track = Join-Path $tmp 'tracked'
New-Item -ItemType Directory -Path $track | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') (Join-Path $track 'server') -Recurse
Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') (Join-Path $track 'schema') -Recurse
git -C $track init -q 2>$null
git -C $track add -A 2>$null
git -C $track -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
Set-GoFile (Join-Path $track 'server\main.go') ((Get-Content (Join-Path $track 'server\main.go') -Raw) + "`n// a tracked edit`n")
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $track 2>&1 | Out-String)
Check 'a tracked edit narrows to its own stack' (($out -match '\[PASS\] go server/') -and ($out -notmatch 'proto')) $out

}

if (Want 'hooks') {
# 23. The generated pre-commit hook, executed the way git executes it. Nothing in
# this suite had ever run one: the checks above assert on the TEXT of the template,
# and the shipped hook was text that read correctly and failed. It probed with
# `command -v qgate.cmd`, which is false under sh.exe even though qgate.cmd runs
# there, so the else branch took a bare `qgate`, exited 127 and BLOCKED the commit.
# `lefthook run pre-commit` typed in a shell passed the whole time, because that
# path goes through bash. Only a real `git commit` distinguishes them.
$genRepo = Join-Path $tmp 'gencommit'
New-Item -ItemType Directory -Path $genRepo | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') (Join-Path $genRepo 'schema') -Recurse
git -C $genRepo init -q 2>$null
$shExe = (Get-Command sh.exe -ErrorAction SilentlyContinue).Source
if ($shExe) {
    Push-Location $genRepo
    try {
        & $shExe (Join-Path $PSScriptRoot 'templates\pre-commit') *> $null
        $shCode = $LASTEXITCODE
    } finally { Pop-Location }
    Check 'the generated hook body runs under sh, the shell git uses' ($shCode -eq 0) "code=$shCode"
} else {
    Write-Output '[skip] no sh.exe -- the generated hook body cannot be run as git would'
}
& pwsh -NoProfile -File $installer -Target $genRepo -NoRun *> $null
git -C $genRepo add -A 2>$null
git -C $genRepo -c user.email=selftest@local -c user.name=selftest commit -qm 'clean' *> $null
$commitCode = $LASTEXITCODE
Check 'a real git commit passes the generated hook on a clean tree' ($commitCode -eq 0) "code=$commitCode"
# ...and is refused when the gate fails, which is the entire job of a pre-commit.
$pfx = Join-Path $genRepo 'schema\example\v1\greeting.proto'
[IO.File]::WriteAllText($pfx, ([IO.File]::ReadAllText($pfx).Replace('string text = 1;', 'string Text = 1;')))
git -C $genRepo add -A 2>$null
git -C $genRepo -c user.email=selftest@local -c user.name=selftest commit -qm 'violation' *> $null
$refuseCode = $LASTEXITCODE
Check 'a real git commit is refused when the gate fails' ($refuseCode -ne 0) "code=$refuseCode"

# ...and the same for a MERGE, which git guards with a different hook entirely. A
# merge that commits on its own runs pre-merge-commit and never pre-commit, so
# wiring one name left `git merge --no-ff` completely unguarded: measured on git
# 2.53, the merge commit lands and no hook runs at all. Two branches that are each
# clean can merge into a tree that does not build, so the break reaches main and the
# next ordinary commit is the one refused, for a failure it did not cause. Driven
# through real git for the same reason as the block above: only real git picks the
# hook name, and `lefthook run pre-commit` would pass either way.
$mrg = Join-Path $tmp 'mergehook'
New-Item -ItemType Directory -Path $mrg | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\proto-fixture') (Join-Path $mrg 'schema') -Recurse
git -C $mrg init -q 2>$null
# Pinned, not inherited: with core.autocrlf=true every checkout below writes the
# fixture back as CRLF, buf format then reports the whole file as misformatted, and
# this block fails for a reason that has nothing to do with which hook git ran.
git -C $mrg config core.autocrlf false 2>$null
& pwsh -NoProfile -File $installer -Target $mrg -NoRun *> $null
git -C $mrg add -A 2>$null
git -C $mrg -c user.email=selftest@local -c user.name=selftest commit -qm 'clean' *> $null
# Whatever `git init` called it: init.defaultBranch is a user setting, and assuming
# "main" left every checkout below on the branch it started on, so the merge merged a
# branch into itself and reported "Already up to date" -- green, for no reason.
$mainBranch = (git -C $mrg rev-parse --abbrev-ref HEAD)
$mpfx = Join-Path $mrg 'schema\example\v1\greeting.proto'
git -C $mrg checkout -q -b bad-branch 2>$null
[IO.File]::WriteAllText($mpfx, ([IO.File]::ReadAllText($mpfx).Replace('string text = 1;', 'string Text = 1;')))
git -C $mrg add -A 2>$null
# --no-verify, because that is how a red commit reaches a branch in the first place.
git -C $mrg -c user.email=selftest@local -c user.name=selftest commit -qm 'violation' --no-verify *> $null
git -C $mrg checkout -q $mainBranch 2>$null
$beforeMerge = (git -C $mrg rev-parse HEAD)
git -C $mrg -c user.email=selftest@local -c user.name=selftest merge --no-ff -m 'merge the violation' bad-branch *> $null
$mergeCode = $LASTEXITCODE
Check 'a merge commit is refused when the merged tree fails the gate' `
    (($mergeCode -ne 0) -and ($beforeMerge -eq (git -C $mrg rev-parse HEAD))) `
    "code=$mergeCode head moved: $($beforeMerge -ne (git -C $mrg rev-parse HEAD))"
git -C $mrg merge --abort *> $null
# ...and a clean merge still lands, or "merges are always broken" would pass the
# check above for entirely the wrong reason.
git -C $mrg checkout -q -b good-branch 2>$null
Set-Content (Join-Path $mrg 'notes.txt') 'harmless'
git -C $mrg add -A 2>$null
git -C $mrg -c user.email=selftest@local -c user.name=selftest commit -qm 'clean branch work' *> $null
git -C $mrg checkout -q $mainBranch 2>$null
$beforeGood = (git -C $mrg rev-parse HEAD)
git -C $mrg -c user.email=selftest@local -c user.name=selftest merge --no-ff -m 'merge the clean branch' good-branch *> $null
$goodCode = $LASTEXITCODE
# Three fields from `rev-list --parents`: the commit itself plus two parents. Two
# fields would be an ordinary commit, i.e. no merge happened at all.
$parents = @((git -C $mrg rev-list --parents -n 1 HEAD) -split ' ')
Check 'a clean merge commit still lands' `
    (($goodCode -eq 0) -and ((git -C $mrg rev-parse HEAD) -ne $beforeGood) -and ($parents.Count -eq 3)) `
    "code=$goodCode fields=$($parents.Count)"

# A hook does not run in the environment a terminal does: git exports GIT_DIR and
# leaves GIT_WORK_TREE unset, and under those two variables git stops DISCOVERING the
# repository and calls the current directory the work tree root. Measured on git 2.53
# in a linked worktree, from `<worktree>/schema`: `rev-parse --show-toplevel` answered
# `<worktree>/schema`, and `--path-format=absolute` only made that wrong answer
# absolute. The proto phase built buf's baseline from that root and handed it
# `<worktree>/schema/.git`, which does not exist -- `could not clone ... exit status 3`
# on every commit from a worktree, for a schema with nothing wrong with it.
#
# Driven through a CHILD pwsh, because the fix clears those variables once for the
# whole process and this file dot-sourced the gate at line 15 -- setting GIT_DIR here
# would prove nothing. Both halves are asserted in the same run: raw git still gets it
# wrong, or the fixture has stopped reproducing the hook environment at all, and the
# gate gets it right anyway.
$hookWt = Join-Path $tmp 'hookwt'
git -C $mrg worktree add -q -b hookenv $hookWt *> $null
$hookGitDir = (& git -C $hookWt rev-parse --path-format=absolute --git-dir 2>$null)
$probe = Join-Path $tmp 'hookenv-probe.ps1'
[IO.File]::WriteAllText($probe, @'
param([string]$Sub, [string]$GitDir, [string]$Detect)
$env:GIT_DIR = $GitDir
Set-Location $Sub
Write-Output "raw=$(git rev-parse --show-toplevel)"
. $Detect
Write-Output "gate=$(Get-RepoRoot (Get-Location).Path)"
'@)
if (-not $hookGitDir) {
    Write-Output '[skip] git refused to make a linked worktree -- the hook-environment check needs one'
} else {
    $hookOut = (& pwsh -NoProfile -File $probe (Join-Path $hookWt 'schema') $hookGitDir `
        (Join-Path $PSScriptRoot 'gate\detect.ps1') 2>&1 | Out-String)
    # .Trim() first: `$` in a multiline regex matches BEFORE the newline but `.` still
    # matches the `\r` in front of it, so every captured path ends in a carriage return.
    $norm = { param($p) ($p.Trim() -replace '/', '\').TrimEnd('\').ToLowerInvariant() }
    $wtPath = & $norm (Resolve-Path $hookWt).Path
    $rawTop = & $norm ([regex]::Match($hookOut, '(?m)^raw=(.*)$').Groups[1].Value)
    $gateTop = & $norm ([regex]::Match($hookOut, '(?m)^gate=(.*)$').Groups[1].Value)
    Check 'the hook environment really does break bare `rev-parse --show-toplevel`' `
        ($rawTop -eq "$wtPath\schema") "raw=$rawTop"
    Check 'the repo root resolves to the worktree root with GIT_DIR exported' `
        ($gateTop -eq $wtPath) "gate=$gateTop want=$wtPath"

    # ...and the symptom itself: the proto phase run from a subdirectory of a linked
    # worktree, in that same environment, must not hand buf a baseline under the
    # subdirectory. Asserted on the failure text rather than only on the exit code, so
    # an unrelated red phase cannot be mistaken for this bug being fixed.
    $bufProbe = Join-Path $tmp 'hookenv-buf.ps1'
    [IO.File]::WriteAllText($bufProbe, @'
param([string]$Sub, [string]$GitDir, [string]$Check)
$env:GIT_DIR = $GitDir
Set-Location $Sub
& pwsh -NoProfile -File $Check -Only proto -Full
'@)
    $bufOut = (& pwsh -NoProfile -File $bufProbe (Join-Path $hookWt 'schema') $hookGitDir `
        (Join-Path $PSScriptRoot 'gate\check.ps1') 2>&1 | Out-String)
    Check 'buf breaking gets a real baseline from inside a hook in a worktree' `
        ($bufOut -notmatch 'could not clone') ($bufOut -replace "`r?`n", ' | ')
}

# A commit hook exports GIT_INDEX_FILE, and buf's baseline clone inherited it and
# rewrote the CALLER's index (buf 1.50.1, exit 0) -- the staged-concurrency guard then
# failed a commit nobody raced. An alternate index with something staged in it, so an
# unchanged tree means untouched, not merely "the same as HEAD". The guard's own true
# positive is the concurrent-commit block below.
if (Get-Command buf -ErrorAction SilentlyContinue) {
    $altIndex = Join-Path $tmp 'alt-index'
    $priorIndex = $env:GIT_INDEX_FILE
    $env:GIT_INDEX_FILE = $altIndex
    try {
        git -C $mrg read-tree HEAD 2>$null
        Set-Content (Join-Path $mrg 'staged-only.txt') 'staged'
        git -C $mrg add staged-only.txt 2>$null
        $treeBefore = (git -C $mrg write-tree)
        Push-Location (Join-Path $mrg 'schema')
        try { $idxOut = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Only proto -Full 2>&1 | Out-String); $idxCode = $LASTEXITCODE }
        finally { Pop-Location }
        $treeAfter = (git -C $mrg write-tree)
    } finally { $env:GIT_INDEX_FILE = $priorIndex }
    Remove-Item (Join-Path $mrg 'staged-only.txt') -Force -ErrorAction SilentlyContinue
    Check "buf breaking leaves the committing hook's index alone" `
        (($idxCode -eq 0) -and ($idxOut -match '\[PASS\] buf breaking') -and ($treeBefore -eq $treeAfter)) `
        "code=$idxCode before=$treeBefore after=$treeAfter $idxOut"
}

# Concurrent commits in one worktree. Git serialises the final write, but it does not
# protect the INDEX while a hook runs, and this hook runs for 40 seconds to five
# minutes -- the gate is what widens the window from milliseconds to minutes. Measured
# on git 2.53: A staged a.txt and began committing, B ran `git add b.txt` during A's
# hook, and A's commit shipped b.txt inside it while B was told `nothing to commit,
# working tree clean` -- a message shaped like success for work just swallowed.
# `.git/index.lock` does not exist during the hook, so there is nothing to poll.
$cc = Join-Path $tmp 'concurrent'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $cc -Recurse
Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $cc
git -C $cc init -q 2>$null
& pwsh -NoProfile -File $installer -Target $cc -NoRun *> $null
git -C $cc add -A 2>$null
git -C $cc -c user.email=selftest@local -c user.name=selftest commit -qm base --no-verify *> $null
Set-Content (Join-Path $cc 'a.txt') 'a'
git -C $cc add a.txt 2>$null
$ccBefore = (git -C $cc rev-parse HEAD)
$ccLog = Join-Path $tmp 'concurrent-commit.out'
$ccProc = Start-Process git -ArgumentList '-C', $cc, '-c', 'user.email=a@local', '-c', 'user.name=a', 'commit', '-m', 'A' `
    -RedirectStandardOutput $ccLog -RedirectStandardError "$ccLog.err" -PassThru -NoNewWindow
# Stage b.txt only once the hook is really running -- a fixed sleep lost the race under
# load (#84: sections in parallel), staging before A's commit had even read the index.
# "Really running" is past the gate's `git write-tree` snapshot: the gate (check.ps1) has
# started a tool that is not git. A non-git descendant of the commit alone was lefthook,
# and under load b.txt still went in before the snapshot (measured: A committed both files).
function Test-HookRunning([int]$RootPid) {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine)
    $kids = @{}
    foreach ($p in $all) { if ($p.ProcessId -ne $p.ParentProcessId) { $kids[[int]$p.ParentProcessId] += @($p) } }
    $below = { param($Id) $q = [Collections.Generic.Queue[int]]::new(); $q.Enqueue($Id)
        while ($q.Count) { foreach ($k in @($kids[$q.Dequeue()] | Where-Object { $_ })) { $k; $q.Enqueue([int]$k.ProcessId) } } }
    $gatePs = @(& $below $RootPid | Where-Object { "$($_.CommandLine)" -match 'check\.ps1' })
    [bool]($gatePs | ForEach-Object { & $below $_.ProcessId } | Where-Object { $_.Name -ne 'git.exe' -and $_.Name -ne 'conhost.exe' })
}
$ccWatch = [Diagnostics.Stopwatch]::StartNew()
while (-not $ccProc.HasExited -and -not (Test-HookRunning $ccProc.Id) -and $ccWatch.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 200 }
# If the gate already finished there was no race to observe, and asserting anything
# about one would be asserting nothing. Skipped out loud rather than counted.
$ccRacing = -not $ccProc.HasExited
if ($ccRacing) {
    Set-Content (Join-Path $cc 'b.txt') 'b'
    git -C $cc add b.txt 2>$null
}
$ccProc.WaitForExit()
$ccOut = (Get-Content $ccLog, "$ccLog.err" -Raw -ErrorAction SilentlyContinue) -join ''
if ($ccRacing) {
    Check 'a commit whose staged files changed under it is refused' `
        (((git -C $cc rev-parse HEAD) -eq $ccBefore) -and ($ccOut -match 'staged files changed while the gate was running')) $ccOut
} else {
    Write-Output '[skip] the gate finished before a second stage could race it'
}
# ...and it must be silent outside a commit: `qgate` in a terminal while the developer
# stages files is not a race, and git sets GIT_INDEX_FILE only for its own hooks. This
# is the half that keeps the guard from becoming a reason nobody can commit.
$r = Invoke-Gate $cc
Check 'the concurrency guard is silent outside a commit' ($r.Out -notmatch 'staged files changed') $r.Out

}

if (Want 'go2') {
# 24. A pin exists to make a run reproducible, so at the full level a mismatch is
# a failure, not a note: a green -Full run on a different compiler than the repo
# declared says nothing about the pinned version. Fast lane still only warns.
$pin = Join-Path $tmp 'pin'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $pin -Recurse
[IO.File]::WriteAllText((Join-Path $pin 'qgate.json'), '{"tools":{"go":"0.0.1"}}')
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $pin -All 2>&1 | Out-String)
Check 'a pin mismatch only warns in the fast lane' (($LASTEXITCODE -eq 0) -and ($out -match '\[WARN\] go .*pins 0\.0\.1')) $out
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $pin -All -Full 2>&1 | Out-String)
Check 'a pin mismatch fails the full level' (($LASTEXITCODE -ne 0) -and ($out -match '\[FAIL\] go .*pins 0\.0\.1')) $out
# ...and a pin that matches must not fail, or the check would be unfalsifiable.
$goVer = if ((& go version) -match 'go(\d+\.\d+(\.\d+)?)') { $Matches[1] } else { $null }
if ($goVer) {
    [IO.File]::WriteAllText((Join-Path $pin 'qgate.json'), "{`"tools`":{`"go`":`"$goVer`"}}")
    if ($fullGreen) {
        $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $pin -All -Full 2>&1 | Out-String)
        Check 'a matching pin does not fail the full level' (($LASTEXITCODE -eq 0) -and ($out -notmatch 'pins')) $out
    } else {
        Write-Output '[skip] no green -Full run here -- a check asserting one cannot be judged'
    }
}

}

if (Want 'core') {
# 25. Deferred updates. Without them the only way to stop an accepted-and-known
# update being reported every session is to stop reading the report -- and a
# deferral with no expiry is just a silence, so `until` is mandatory and an
# expired one comes back louder than it left.
$def = Join-Path $tmp 'defer'
New-Item -ItemType Directory -Path $def | Out-Null
$future = (Get-Date).AddDays(30).ToString('yyyy-MM-dd')
$past = (Get-Date).AddDays(-5).ToString('yyyy-MM-dd')
[IO.File]::WriteAllText((Join-Path $def 'qgate.deferrals.json'), @"
{"dependencies":[
 {"name":"go","until":"$future","reason":"linter cannot parse the new syntax"},
 {"name":"rust/cargo","until":"$past","reason":"was waiting on the edition bump"},
 {"name":"nodate","reason":"missing until"}
]}
"@)
# These assertions used to be made against a LIVE run and were not sound. Two of them
# went red on a perfectly healthy gate whenever the registry was unreachable --
# measured, same commit and same machine minutes apart: 118/118, then 116/118. They
# also depended, silently, on THIS machine's cargo happening to be behind, so an
# up-to-date cargo failed them exactly as an outage did. And the first one passed
# OFFLINE for no reason at all: an absent [OUTDATED] satisfies its -notmatch whether a
# live deferral hid the finding or the network simply never produced one.
#
# So the contract is pinned to fixed inputs. The seam is the cache: outdated writes one
# [OUTDATED] line per finding to a per-repo file in TEMP, and -Summary is the only
# caller allowed to answer from it, so seeding that file fixes BOTH halves of the
# input -- installed version and latest version -- with no registry in the loop.
function Set-Deferrals([string]$RepoRoot, [string]$Json) {
    $f = Join-Path $RepoRoot 'qgate.deferrals.json'
    [IO.File]::WriteAllText($f, $Json)
    # Backdated on purpose: the cache is trusted only while it is STRICTLY newer than
    # every manifest, and two writes in the same instant are not strictly ordered.
    (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-5)
}
function Set-OutdatedCache([string]$RepoRoot, [string[]]$Lines) {
    Set-Content -Path (Join-Path ([IO.Path]::GetTempPath()) `
        "quality-gate-outdated-$(Get-PathKey (Resolve-Path $RepoRoot).Path).txt") -Value ($Lines -join "`n")
}
function Get-Summary([string]$RepoRoot, [switch]$NoAdvisory) {
    # The suite runs with QGATE_NO_ADVISORY=1; the cache path under test needs it off.
    $env:QGATE_NO_ADVISORY = if ($NoAdvisory) { '1' } else { $null }
    try { (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $RepoRoot -Summary 2>&1 | Out-String) }
    finally { $env:QGATE_NO_ADVISORY = '1' }
}
$fixedFinding = '[OUTDATED] tool rust/cargo 1.0.0 -> 2.0.0'

Set-Deferrals $def '{"dependencies":[]}'
Set-OutdatedCache $def @($fixedFinding)
$s = Get-Summary $def
Check 'a finding with no deferral is reported' `
    (($s -match 'dependency update\(s\) available') -and ($s -notmatch 'have expired')) $s

Set-Deferrals $def "{`"dependencies`":[{`"name`":`"rust/cargo`",`"until`":`"$future`",`"reason`":`"waiting on the edition bump`"}]}"
Set-OutdatedCache $def @($fixedFinding)
$s = Get-Summary $def
Check 'a live deferral hides the finding' `
    (($s -notmatch 'dependency update\(s\) available') -and ($s -notmatch 'have expired')) $s

Set-Deferrals $def "{`"dependencies`":[{`"name`":`"rust/cargo`",`"until`":`"$past`",`"reason`":`"was waiting on the edition bump`"},{`"name`":`"nodate`",`"reason`":`"missing until`"}]}"
Set-OutdatedCache $def @($fixedFinding)
$s = Get-Summary $def
# Both halves in one run: the expiry is announced AND the finding it was hiding is
# back. An implementation that printed the marker and went on suppressing the finding
# would satisfy either half alone.
Check 'an expired deferral is reported and its finding comes back' `
    (($s -match 'deferral\(s\).*have expired') -and ($s -match 'dependency update\(s\) available')) $s
# Printed ahead of the cache branch, so it must survive the path the pre-commit run
# actually takes -- this used to be asserted only against the live report.
Check 'a deferral without until is a warning, not a silent skip' ($s -match "entry for 'nodate' needs 'until'") $s
# #84: QGATE_NO_ADVISORY=1 drops the -Summary note (the same seeded finding printed it
# above), and the deferrals warning still prints.
Set-OutdatedCache $def @($fixedFinding)
$s = Get-Summary $def -NoAdvisory
Check 'QGATE_NO_ADVISORY=1 drops the update note and keeps the deferrals warning' `
    (($s -notmatch 'dependency update\(s\) available') -and ($s -notmatch 'have expired') -and ($s -match "entry for 'nodate' needs 'until'")) $s

# The live path is still worth one smoke test -- a real registry answer flowing into a
# real deferral is not what the cache path proves -- but only when its subject exists.
# The precondition is checked out loud instead of being assumed: neither the registry
# being up nor this machine's cargo being behind is anything this suite arranges.
Set-Deferrals $def '{"dependencies":[]}'
$live = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $def 2>&1 | Out-String)
Check 'qgate outdated never fails, deferrals included' ($LASTEXITCODE -eq 0) $live
if ($live -match '\[OUTDATED\] tool rust/cargo') {
    Set-Deferrals $def "{`"dependencies`":[{`"name`":`"rust/cargo`",`"until`":`"$past`",`"reason`":`"was waiting on the edition bump`"}]}"
    $live = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $def 2>&1 | Out-String)
    Check 'a live registry answer still reaches the deferral logic' `
        (($live -match '\[DEFERRAL EXPIRED\] rust/cargo') -and ($live -match '\[OUTDATED\] tool rust/cargo')) $live
} else {
    Write-Output '[skip] no live rust/cargo finding to defer -- registry unreachable, or this cargo is current'
}

# The full run's advisory has a deadline. A copy of gate/ with outdated.ps1 swapped for
# a stub, because a stalled registry is not something this suite can arrange. The hung
# stub starts a child of its own: the tree is killed, not just the pwsh parent. Costs
# the real 30s -- a knob only a test turns is not worth shipping to every hook.
$advGate = Join-Path $tmp 'advgate'
Copy-Item (Join-Path $PSScriptRoot 'gate') $advGate -Recurse
$advRepo = Join-Path $tmp 'adv repo'
New-Item -ItemType Directory -Path $advRepo | Out-Null
git -C $advRepo init -q 2>$null
Set-Content (Join-Path $advRepo 'readme.txt') 'hello'
$advStub = Join-Path $advGate 'outdated.ps1'
[IO.File]::WriteAllText($advStub, "param([string]`$Root, [switch]`$Summary)`n'[INFO] stub advisory for ' + `$Root`n")
$out = (& pwsh -NoProfile -File (Join-Path $advGate 'check.ps1') -Root $advRepo -Full 2>&1 | Out-String)
Check 'a finished advisory still reaches the report, root with a space intact' `
    (($LASTEXITCODE -eq 0) -and ($out -match [regex]::Escape("[INFO] stub advisory for $advRepo"))) $out
$childPid = Join-Path $tmp 'adv-child.pid'
[IO.File]::WriteAllText($advStub, @"
param([string]`$Root, [switch]`$Summary)
`$c = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 300' -NoNewWindow -PassThru
Set-Content '$childPid' `$c.Id
Start-Sleep -Seconds 300
"@)
$sw = [Diagnostics.Stopwatch]::StartNew()
$out = (& pwsh -NoProfile -File (Join-Path $advGate 'check.ps1') -Root $advRepo -Full -Quiet 2>&1 | Out-String)
$advCode = $LASTEXITCODE
$sw.Stop()
$childAlive = [bool](Get-Process -Id ([int](Get-Content $childPid -ErrorAction SilentlyContinue)) -ErrorAction SilentlyContinue)
Check 'a hung advisory is cut off, named under -Quiet, and does not fail the run' `
    (($advCode -eq 0) -and ($sw.Elapsed.TotalSeconds -lt 90) -and -not $childAlive -and
    ($out -match '\[WARN\] dependency update advisory timed out after 30s; update status is unknown')) `
    "code=$advCode elapsed=$($sw.Elapsed.TotalSeconds) childAlive=$childAlive $out"

# 26. An unreadable qgate.deferrals.json must say so ONCE. `@($null)` iterates one
# null element, so the correct "not readable" line was followed by a second warning
# about "entry 1" that no entry ever produced -- a right outcome with an invented
# reason, the shape PLAYBOOK.md 0.1 is about.
$defBad = Join-Path $tmp 'defer-bad'
New-Item -ItemType Directory -Path $defBad | Out-Null
[IO.File]::WriteAllText((Join-Path $defBad 'qgate.deferrals.json'), '{ this is not json')
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\outdated.ps1') -Root $defBad 2>&1 | Out-String)
Check 'an unreadable deferrals file is reported, and the run still passes' `
    (($LASTEXITCODE -eq 0) -and ($out -match 'qgate\.deferrals\.json is not readable')) $out
Check 'an unreadable deferrals file is not also blamed on a missing name/reason' `
    ($out -notmatch "needs both 'name' and 'reason'") $out

}

if (Want 'go2') {
# 27. The same warning has to reach the -Full gate run. It was emitted only after
# the -Summary early return, and -Summary is the path -Full calls -- so a malformed
# qgate.deferrals.json was silently ignored exactly where it guards a commit, while
# README claimed a [WARN] and not a silent skip.
$defFull = Join-Path $tmp 'defer-full'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $defFull -Recurse
[IO.File]::WriteAllText((Join-Path $defFull 'qgate.deferrals.json'), '{"dependencies":[{"name":"go"}]}')
if ($fullGreen) {
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $defFull -All -Full 2>&1 | Out-String)
$defCode = $LASTEXITCODE
Check 'a malformed deferral is warned about on a -Full run' `
    (($defCode -eq 0) -and ($out -match "\[WARN\] qgate\.deferrals\.json entry 1 needs both 'name' and 'reason'")) "code=$defCode $out"
# A check that asserted `-notmatch '[DEFERRED]'` stood here and was deleted: a
# malformed entry is stored with no Name, and Split-Deferred iterates only entries
# that have one, so it could not emit [DEFERRED] for one either before or after the
# fix. An assertion that cannot fail is decoration, not the 0.1 absence check.
# What it should have been guarding is below: the warning has to reach the mode the
# hook actually runs in.
#
# -Quiet is what the generated pre-commit hook uses, and the warning was gated on
# `-not $Quiet` -- so a repo whose qgate.deferrals.json the gate cannot read got
# NOTHING at all (output length 0, exit 0) precisely where the gate guards a commit.
$outQ = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $defFull -All -Full -Quiet 2>&1 | Out-String)
$qCode = $LASTEXITCODE
Check 'a malformed deferral still reaches the -Quiet run the hook uses' `
    (($qCode -eq 0) -and ($outQ -match "\[WARN\] qgate\.deferrals\.json entry 1 needs both 'name' and 'reason'")) "code=$qCode $outQ"
# ...without -Quiet becoming chatty: a passing run stays silent about everything
# that is not the gate's own config being broken.
Check '-Quiet on a green run still says nothing else' `
    (($outQ -notmatch '\[PASS\]') -and ($outQ -notmatch '\[INFO\]') -and ($outQ -notmatch 'golangci\.yml')) $outQ
Remove-Item (Join-Path $defFull 'qgate.deferrals.json')
$outQ = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $defFull -All -Full -Quiet 2>&1 | Out-String)
Check '-Quiet prints nothing at all on a clean pass' `
    (($LASTEXITCODE -eq 0) -and [string]::IsNullOrWhiteSpace($outQ)) $outQ
} else {
    Write-Output '[skip] no green -Full run here -- checks asserting one cannot be judged'
}

}

if (Want 'core') {
# 28. Issue #3 again, through a different door: `-Only <stack the gate does not
# implement>` printed [SKIP] not implemented and exited 0 -- a green pipeline over
# zero checks, which is the exact thing `-Only nonsense` was made fatal for. It has
# no branch of its own any more; the zero-phase invariant below is what fails it.
# Copied OUT of this repository on purpose. The fixture directory itself sits inside a
# git work tree, which is the base stack's marker -- base would then run real phases
# here and the run would no longer be the empty one these checks are about. The
# invariant is what is under test; base has its own section below.
$py = Join-Path $tmp 'python'
Copy-Item (Join-Path $PSScriptRoot 'testdata\python-fixture') $py -Recurse
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $py -Only 'python' 2>&1 | Out-String)
$pyCode = $LASTEXITCODE
Check '-Only on a detected but unimplemented stack fails the run' ($pyCode -ne 0) "code=$pyCode $out"
Check '-Only python gives the reason that applied' ($out -match 'python .*not implemented') $out
# The other -Only failure mode prints a different reason; if that one fired, the
# right exit code would be standing on the wrong explanation.
Check '-Only python is not blamed on an undetected stack' ($out -notmatch 'no such stack detected here') $out

# 29. THE INVARIANT: a run that executed zero check phases is not green. The rule is
# about phases that actually ran, never about which stacks were detected -- and both
# halves have to be stated or it collapses into "python never fails" (the old check
# here) or into "python always fails".
# Alone, an unimplemented stack IS the whole run and nothing was checked:
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $py -All 2>&1 | Out-String)
$pyAllCode = $LASTEXITCODE
Check '-All over an unimplemented stack alone fails: nothing was checked' `
    (($pyAllCode -ne 0) -and ($out -match '\[FAIL\] no check phase ran') -and ($out -match '\[SKIP\] python .*not implemented')) `
    "code=$pyAllCode $out"
# ...and the reason is the empty run, not the -Only rule, which was never invoked.
Check '-All over an unimplemented stack is not blamed on -Only' ($out -notmatch '\-Only') $out
# Beside a stack that did real work the same python marker is only a note: phases
# ran, so the run stands. Failing here would block work the gate never promised.
$mixed = Join-Path $tmp 'mixed'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $mixed -Recurse
Copy-Item (Join-Path $py 'pyproject.toml') $mixed
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $mixed -All 2>&1 | Out-String)
$mixCode = $LASTEXITCODE
Check '-All passes when a real stack ran and only flags the unimplemented one' `
    (($mixCode -eq 0) -and ($out -match '\[PASS\] go') -and ($out -match '\[SKIP\] python .*not implemented')) "code=$mixCode $out"
Check 'a run that did check something is not called empty' ($out -notmatch 'no check phase ran') $out
# The web stack is the same hole with no unimplemented stack in sight: every phase
# of it is conditional on a config file or a package script, so a project with a
# node_modules but no eslint/stylelint config, no tsconfig, no build script and no
# lockfile ran nothing at all and was reported [PASS], exit 0.
$wz = Join-Path $tmp 'webzero'
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') $wz -Recurse
New-Item -ItemType Directory -Path (Join-Path $wz 'node_modules\.bin') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $wz 'package.json'), '{"name":"webzero","private":true,"type":"module"}')
$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $wz -Only 'web' -Full 2>&1 | Out-String)
$wzCode = $LASTEXITCODE
Check 'a web stack whose every phase is conditional cannot report a green run' `
    (($wzCode -ne 0) -and ($out -match '\[FAIL\] no check phase ran')) "code=$wzCode $out"
Check 'a stack that ran no phase is not called [PASS]' ($out -notmatch '\[PASS\] web') $out
# The legitimate empty run must survive all of this: a clean tree on the fast lane
# says so and exits 0, and section 20 above proves it still does.

# 30. What -Only was actually handed. Both of these ended in a defensible-looking
# outcome standing on a reason about something else entirely.
$gate = Join-Path $PSScriptRoot 'gate\check.ps1'
# An empty value is the PowerShell absence trap: `if ($Only)` read `-Only ''` as
# "no filter given" and quietly widened the run to every stack.
$out = (& pwsh -NoProfile -File $gate -Root $mixed -Only '' -Full 2>&1 | Out-String)
$emptyCode = $LASTEXITCODE
Check 'an empty -Only is refused, not read as no filter' `
    (($emptyCode -ne 0) -and ($out -match '\[FAIL\] -Only was given an empty value')) "code=$emptyCode $out"
Check 'an empty -Only does not silently widen the run' ($out -notmatch 'checking (every stack|all of them)') $out
# A second value used to bind to -Baseline positionally, so the user asking for two
# stacks was told the baseline revision did not exist.
$out = (& pwsh -NoProfile -File $gate -Root $mixed -Only 'go' 'banana' -Full 2>&1 | Out-String)
$strayCode = $LASTEXITCODE
Check 'a stray value after -Only is refused' `
    (($strayCode -ne 0) -and ($out -match 'unexpected argument\(s\): banana')) "code=$strayCode $out"
Check 'a stray value after -Only is not reported as a missing baseline' `
    ($out -notmatch 'baseline revision not found') $out
# ...but PowerShell parses the documented `-Only go,web` as an ARRAY and the shim
# flattens it into two arguments, so the help text's own example was refused by the
# error message that then quoted it back as the remedy. Stack names after -Only are
# its value, however the shell split them.
$out = (& pwsh -NoProfile -File $gate -Root $mixed -Only 'go' 'python' 2>&1 | Out-String)
$splitCode = $LASTEXITCODE
Check 'stack names split by the shell are read as the -Only list' `
    (($splitCode -eq 0) -and ($out -match '\[PASS\] go') -and ($out -match '\[SKIP\] python')) "code=$splitCode $out"
# ...and the spelling that works has to keep working, or the validation would be
# worse than the bug: one value, comma separated, is a list of stacks.
$out = (& pwsh -NoProfile -File $gate -Root $mixed -Only 'go,python' 2>&1 | Out-String)
$listCode = $LASTEXITCODE
Check '-Only takes a comma-separated list as one value' `
    (($listCode -eq 0) -and ($out -match '\[PASS\] go') -and ($out -match '\[SKIP\] python')) "code=$listCode $out"
Check '-Only does not read the whole list as one stack name' ($out -notmatch 'no such stack detected here') $out

# 30a. Fail-fast across stacks used to `break` the loop, and the report simply ended:
# a red go stack left the web stack with no line at all, indistinguishable from a repo
# that has no web stack. The work is still skipped; the skipping has to be on the record.
$twin = Join-Path $tmp 'twin'
New-Item -ItemType Directory -Path $twin | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') (Join-Path $twin 'go') -Recurse
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') (Join-Path $twin 'web') -Recurse
Set-GoFile (Join-Path $twin 'go\main.go') @'
package main

import "fmt"

// Add returns the sum of a and b.
func Add(a, b int) int { return a + b }

func main() {
	fmt.Printf("%d", "not an int")
	_ = Add(1, 2)
}
'@
$out = (& pwsh -NoProfile -File $gate -Root $twin -All 2>&1 | Out-String)
$twinCode = $LASTEXITCODE
Check 'a failing stack still fails the run' (($twinCode -ne 0) -and ($out -match '\[FAIL\] go go/')) "code=$twinCode $out"
Check 'a stack skipped by an earlier failure says so' `
    ($out -match '\[SKIP\] web web/.*earlier stack failed') $out

# 31. Order of the two early returns. `[SKIP] no known stack found` sat above the
# -Only validation, so in a repo with no marker file at all `-Only go` never reached
# it: exit 0, nothing checked, and a message about the repo rather than about the
# flag -- the same green-over-zero-checks lie as `-Only nonsense`, one line earlier.
$bare = Join-Path $tmp 'nostack'
New-Item -ItemType Directory -Path $bare | Out-Null
git -C $bare init -q 2>$null
$out = (& pwsh -NoProfile -File $gate -Root $bare -Only 'go' -Full 2>&1 | Out-String)
$bareCode = $LASTEXITCODE
Check '-Only in a repo with no stack at all fails' `
    (($bareCode -ne 0) -and ($out -match '\[FAIL\] -Only go -- no such stack detected here')) "code=$bareCode $out"
Check '-Only is not waved through as a repo the gate knows nothing about' `
    ($out -notmatch 'no known stack found') $out
# ...and the free pass itself stays -- but it is now about a directory that is not a
# git work tree. A repo with no marker file has the base stack (section 37), whose
# marker IS the repository, so `no known stack found` there would be a lie.
$bareNoGit = Join-Path $tmp 'nostack-nogit'
New-Item -ItemType Directory -Path $bareNoGit | Out-Null
$out = (& pwsh -NoProfile -File $gate -Root $bareNoGit -Full 2>&1 | Out-String)
Check 'a directory with no marker file is still skipped, not failed' `
    (($LASTEXITCODE -eq 0) -and ($out -match '\[SKIP\] no known stack found')) $out
# In a repository the same absence of markers is the base stack instead, and a green,
# zero-cost run there is a run that named every phase it did not perform.
# -All, because $bare is clean and the fast lane's own `[SKIP] no changes` would exit
# before any stack ran -- which would prove nothing about which stacks are there.
$out = (& pwsh -NoProfile -File $gate -Root $bare -All -Full 2>&1 | Out-String)
Check 'a repo with no marker file gets base, not "no known stack"' `
    (($LASTEXITCODE -eq 0) -and ($out -match 'base \(git work tree\)') -and ($out -notmatch 'no known stack found')) $out

}

if (Want 'go2') {
# 32. A tool binary older than the module's go directive. Both failures are opaque:
# golangci-lint refuses to load its config, govulncheck names every file in the repo
# and four more inside the standard library. The verdict has to name the binary and
# the `go install` line instead. Driven through the helper rather than a fixture,
# because a go.mod the local toolchain cannot build fails at `go build` long before
# either tool runs -- and the machine's own tool versions are not a fixed point.
$installLine = 'go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest'
Check 'the Go a tool was built with is readable' `
    ((Get-GoBuiltWith 'golangci-lint') -match '^\d+\.\d+(\.\d+)?$')
# Build info, never the tool's own version output: `govulncheck -version` prints a
# `Go:` line that is the toolchain active in the CURRENT DIRECTORY, so the same binary
# reads go1.26.2 from a plain directory and go1.27.1 inside a module whose go
# directive pulls a newer toolchain. Comparing THAT against the module's directive
# compares the module with itself and can never fire. The number has to come out of
# the binary, and this check reads it independently to say so -- from inside a module,
# which is where every gate phase runs.
$vulnExe = (Get-Command govulncheck -ErrorAction SilentlyContinue).Source
if ($vulnExe) {
    $truth = if (((& go version -m $vulnExe) | Select-Object -First 1) -match ':\s+go(\d+\.\d+(?:\.\d+)?)') { $Matches[1] }
    Push-Location $go
    $inModule = Get-GoBuiltWith 'govulncheck'
    Pop-Location
    Check 'built-with is read from the binary, not from its own version output' `
        (($truth) -and ($inModule -eq $truth)) "binary=$truth read=$inModule"
}
$stale = Test-GoToolStale 'golangci-lint' '99.0' $installLine
Check 'a tool older than the go directive is named, with its reinstall line' `
    (($stale -match 'built with go\d+\.\d+') -and ($stale -match 'targets go99\.0') -and ($stale -match [regex]::Escape($installLine))) $stale
Check 'a tool newer than the go directive is not reported' `
    ($null -eq (Test-GoToolStale 'golangci-lint' '1.0' $installLine)) `
    (Test-GoToolStale 'golangci-lint' '1.0' $installLine)
Check 'a module with no go directive is not a staleness verdict' `
    ($null -eq (Test-GoToolStale 'golangci-lint' '' $installLine))

# 33. Third-party Go inside an npm tree. `golangci-lint run ./...` from the module
# root walks into web/node_modules -- npm packages ship .go files (eslint pulls in
# `flatted`, which contains a Go implementation) -- and a go+web repo went red on
# code nobody there wrote. The shipped .golangci.yml has to exclude it, and the
# control below proves the fixture really does trip the linter.
$nm = Join-Path $tmp 'nodemods'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $nm -Recurse
Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $nm
$thirdParty = @'
package thirdparty

// Has reports whether s contains v.
func Has(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
'@
New-Item -ItemType Directory -Path (Join-Path $nm 'own') | Out-Null
Set-GoFile (Join-Path $nm 'own\has.go') $thirdParty
$r = Invoke-Gate $nm
Check 'the control file really is a linter finding' `
    (($r.Code -ne 0) -and ($r.Out -match 'slicescontains')) $r.Out
Remove-Item (Join-Path $nm 'own') -Recurse -Force
$vendored = Join-Path $nm 'web\node_modules\flattish'
New-Item -ItemType Directory -Path $vendored -Force | Out-Null
Set-GoFile (Join-Path $vendored 'has.go') $thirdParty
$r = Invoke-Gate $nm
Check 'the shipped config keeps the linter out of node_modules' `
    (($r.Code -eq 0) -and ($r.Out -notmatch 'slicescontains')) $r.Out

# 34. `wire` takes the gate's own name for "which repository". -Root is documented
# under the gate flags and wire took only -Target, so `qgate wire -Root <path>` died
# with a raw "A parameter cannot be found that matches parameter name 'Root'".
git -C $nm init -q 2>$null
$wireRoot = (& pwsh -NoProfile -File $installer -Root $nm -NoRun -NoHook 2>&1 | Out-String)
Check 'wire accepts -Root as the repository to wire' `
    (($LASTEXITCODE -eq 0) -and ($wireRoot -match [regex]::Escape($nm))) "code=$LASTEXITCODE $wireRoot"

# #82: govulncheck honours qgate.deferrals.json "vulnerabilities" too (ids from -format
# openvex). A stand-in, so no network; the rest of the -Full run still needs $fullGreen.
if ($fullGreen) {
    $gvRepo = Join-Path $tmp 'govuln-ack'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $gvRepo -Recurse
    $gvShim = Join-Path $tmp 'govulncheck-shim'
    New-VulnShim $gvShim 'govulncheck' 'openvex' `
        '{"statements":[{"vulnerability":{"name":"GO-2026-5932"},"status":"affected"},{"vulnerability":{"name":"GO-2026-7777","aliases":["GHSA-aaaa-bbbb-cccc"]},"status":"affected"},{"vulnerability":{"name":"GO-2021-0001"},"status":"not_affected"}]}' `
        'Vulnerability #1: GO-2026-5932 shimtext' 3
    $gvPrior = $env:PATH
    $gvAck = { param($Entries) [IO.File]::WriteAllText((Join-Path $gvRepo 'qgate.deferrals.json'), (@{ vulnerabilities = $Entries } | ConvertTo-Json -Depth 5)) }
    try {
        $env:PATH = "$gvShim$([IO.Path]::PathSeparator)$gvPrior"
        & $gvAck @(@{ id = 'GO-2026-5932'; until = '2099-01-01'; reason = 'no fix' }, @{ id = 'GHSA-aaaa-bbbb-cccc'; until = '2099-01-01'; reason = 'no fix either' })
        $out = (& pwsh -NoProfile -File $gate -Root $gvRepo -All -Full -Only go 2>&1 | Out-String); $code = $LASTEXITCODE
        Check 'govulncheck: every affected advisory acknowledged passes and names each one' `
            (($code -eq 0) -and ($out -match '\[PASS\] govulncheck') -and
            ($out -match '\[WARN\] qgate\.deferrals\.json: govulncheck GO-2026-5932 acknowledged until 2099-01-01 -- no fix') -and
            ($out -match 'govulncheck GHSA-aaaa-bbbb-cccc acknowledged') -and ($out -notmatch 'GO-2021-0001')) "code=$code $out"
        & $gvAck @(@{ id = 'GO-2026-5932'; until = '2099-01-01'; reason = 'no fix' })
        $out = (& pwsh -NoProfile -File $gate -Root $gvRepo -All -Full -Only go 2>&1 | Out-String); $code = $LASTEXITCODE
        Check 'govulncheck: a new advisory beside an acknowledged one still fails, named' `
            (($code -ne 0) -and ($out -match '\[FAIL\] govulncheck') -and ($out -match 'not acknowledged: GO-2026-7777') -and
            ($out -notmatch 'not acknowledged: GO-2026-5932') -and ($out -match 'shimtext')) "code=$code $out"
        & $gvAck @(@{ id = 'GO-2026-5932'; until = '2020-01-01'; reason = 'no fix' }, @{ id = 'GO-2026-7777'; until = '2099-01-01'; reason = 'no fix either' })
        $out = (& pwsh -NoProfile -File $gate -Root $gvRepo -All -Full -Only go 2>&1 | Out-String); $code = $LASTEXITCODE
        Check 'govulncheck: an expired acknowledgement fails, and says it expired' `
            (($code -ne 0) -and ($out -match 'acknowledgement expired: GO-2026-5932 was acknowledged until 2020-01-01')) "code=$code $out"
    } finally { $env:PATH = $gvPrior }
} else { Write-Output '[skip] govulncheck acknowledgements -- a -Full run is not green on this machine' }

}

if (Want 'custom') {
# 35. Custom checks the repository declares in its own qgate.json. They are arbitrary
# command lines out of a file in the working tree, so the whole feature stands on the
# trust gate: nothing runs until somebody on this machine has read the commands. The
# store is a per-user file, so LOCALAPPDATA is redirected for the whole block -- a
# self-test that wrote into the developer's real trust store would be doing to them
# exactly what the trust gate exists to prevent.
$cust = Join-Path $tmp 'custom'
New-Item -ItemType Directory -Path $cust | Out-Null
$custJson = Join-Path $cust 'qgate.json'
$priorLocal = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $tmp 'trusthome'
# ...and QGATE_HOME, which OVERRIDES that redirect: on a machine where it is set, every
# check below would otherwise be writing into the developer's real trust store, which
# is precisely what redirecting LOCALAPPDATA exists to prevent.
$priorQGate = $env:QGATE_HOME
$env:QGATE_HOME = $null
function Invoke-Trust([string]$Repo, [switch]$Remove) {
    (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\trust.ps1') -Root $Repo -Remove:$Remove 2>&1 | Out-String)
}
try {
    # `fast` runs at both levels, `full` (the default) only under -Full -- the same
    # split every other phase uses.
    [IO.File]::WriteAllText($custJson,
        '{"checks":[{"name":"quick","run":"exit 0","level":"fast"},{"name":"heavy","run":"exit 0"}]}')
    $r = Invoke-Gate $cust
    Check 'a declared check does not run until the repo is trusted' `
        (($r.Code -eq 0) -and ($r.Out -match '\[SKIP\] custom -- untrusted qgate\.json checks \(run: qgate trust\)')) $r.Out
    # The absence half, and it is the whole rule: an untrusted repo is a [SKIP], never a
    # [FAIL]. Refusing to run a command is not a verdict on the code, and a repository
    # nobody has trusted yet must not be one nobody can commit to -- including through
    # the zero-phase invariant, which this is the third documented exemption from.
    Check 'an untrusted repo is skipped, not failed' ($r.Out -notmatch '\[FAIL\]') $r.Out

    # `qgate trust` is the one place the exact command is shown to the person allowing
    # it, so printing a summary instead of the string would defeat the whole gate.
    $t = Invoke-Trust $cust
    Check 'qgate trust prints every check and the store it writes' `
        (($t -match '(?m)^\s+quick\b') -and ($t -match '(?m)^\s+exit 0\s*$') -and ($t -match 'trusted\.json')) $t
    $r = Invoke-Gate $cust
    Check 'a trusted check runs and passes' (($r.Code -eq 0) -and ($r.Out -match '\[PASS\] quick')) $r.Out
    Check 'a full-level check is not run in the fast lane' `
        (($r.Out -match '\[SKIP\] heavy -- level full') -and ($r.Out -notmatch '\[PASS\] heavy')) $r.Out
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cust -All -Full 2>&1 | Out-String)
    Check 'a full-level check runs at the full level' `
        (($LASTEXITCODE -eq 0) -and ($out -match '\[PASS\] heavy')) $out
    # `custom` is a stack like any other, or -Only would be a documented flag that
    # cannot name it.
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cust -Only 'custom' -Full 2>&1 | Out-String)
    Check '-Only custom selects the stack' (($LASTEXITCODE -eq 0) -and ($out -match '\[PASS\] custom')) $out
    # #75: a phase line printed after more than 6000 chars of detail used to fall off the
    # head-truncated report. Both sides: the later status line survives, the detail is
    # still capped.
    [IO.File]::WriteAllText($custJson,
        '{"checks":[{"name":"loud","run":"1..200 | % { ''x'' * 60 }; exit 1","level":"fast"},{"name":"later","run":"exit 0","level":"fast"}]}')
    $null = Invoke-Trust $cust
    $r = Invoke-Gate $cust
    Check 'a status line after 6000+ chars of detail is still reported' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] loud') -and ($r.Out -match '\[SKIP\] later -- not run')) $r.Out
    Check 'the detail of a failing stack is still capped' `
        (($r.Out -match '\.\.\.\[truncated, \d+ more chars\]') -and ($r.Out.Length -lt 8000)) "len=$($r.Out.Length)"

    # Trust is a hash of the checks, so editing the command re-arms the gate. This is
    # the case the feature exists to survive: a pull, a branch switch or a teammate
    # changing `run` under a repo that was trusted yesterday.
    [IO.File]::WriteAllText($custJson,
        '{"checks":[{"name":"quick","run":"exit 1","level":"fast"},{"name":"heavy","run":"exit 0"}]}')
    $r = Invoke-Gate $cust
    Check 'editing the run string of a trusted check revokes the trust' `
        (($r.Code -eq 0) -and ($r.Out -match 'untrusted qgate\.json checks')) $r.Out
    # ...and the edited command really did not run: a revocation that still executed it
    # would satisfy the line above and be worth nothing.
    Check 'the edited command is not executed' ($r.Out -notmatch '\[(PASS|FAIL)\] quick') $r.Out

    # A non-zero exit is the finding, and the output plus the command line is what a
    # reader acts on -- no other phase's output has to name the tool that produced it.
    [IO.File]::WriteAllText($custJson,
        '{"checks":[{"name":"boom","run":"Write-Output the-real-reason; exit 3","level":"fast"}]}')
    Invoke-Trust $cust | Out-Null
    $r = Invoke-Gate $cust
    Check 'a check that exits non-zero fails the gate under its own name' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] boom') -and ($r.Out -match 'the-real-reason') -and
            ($r.Out -match 'run: Write-Output the-real-reason; exit 3')) $r.Out

    # A command that never comes back is not a command that failed, and the raw output
    # cannot tell them apart: a killed process usually printed nothing at all.
    [IO.File]::WriteAllText($custJson,
        '{"checks":[{"name":"hang","run":"Start-Sleep 30","level":"fast","timeoutSec":1}]}')
    Invoke-Trust $cust | Out-Null
    $r = Invoke-Gate $cust
    Check 'a check that outruns its timeout is killed and named as a timeout' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] hang -- timeout after 1s')) $r.Out

    # A command that exits 0 while a process it started keeps running is a green verdict
    # over a held port, and the orphan -- whose parent is already gone -- is exactly what
    # the .Kill($true) above cannot see. The bystander is started FIRST and is the same
    # executable as the leak: the walk has to match identity, not names, or this process
    # dies with them.
    $bystander = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 90' -PassThru -WindowStyle Hidden
    try {
        [IO.File]::WriteAllText($custJson,
            '{"checks":[{"name":"leaky","run":"Start-Process pwsh -ArgumentList ''-NoProfile'',''-Command'',''Start-Sleep 90'' -WindowStyle Hidden; exit 0","level":"fast"}]}')
        Invoke-Trust $cust | Out-Null
        $r = Invoke-Gate $cust
        # The count is not pinned: the orphaned pwsh drags its own conhost.exe along, and
        # a walk that dropped that one would be matching on a name again.
        Check 'a check that leaves a process behind fails even though it exited 0' `
            (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] leaky') -and
                ($r.Out -match '\[LEAK\] leaky left \d+ process\(es\) running:')) $r.Out
        # Named by pid, and then actually ended: a report that says `killed` while the
        # process is still holding the port is worth less than no report at all.
        $leakPid = if ($r.Out -match '\[LEAK\][^\r\n]*pid (\d+) pwsh') { [int]$Matches[1] } else { 0 }
        Check 'the leaked process is named by pid and is gone after the run' `
            (($leakPid -gt 0) -and ($r.Out -match ' -- killed') -and
                (-not (Get-Process -Id $leakPid -ErrorAction SilentlyContinue))) $r.Out
        Check 'a process the gate did not start is left alone' `
            (-not $bystander.HasExited) "bystander pid $($bystander.Id)"

        # ...and a repository that leaves nothing behind reads exactly as it did before:
        # a cleanup that reported on every ordinary run would be noise nobody can act on.
        [IO.File]::WriteAllText($custJson, '{"checks":[{"name":"tidy","run":"exit 0","level":"fast"}]}')
        Invoke-Trust $cust | Out-Null
        $r = Invoke-Gate $cust
        Check 'a check that leaves nothing behind still passes, with no leak line' `
            (($r.Code -eq 0) -and ($r.Out -match '\[PASS\] tidy') -and ($r.Out -notmatch 'LEAK')) $r.Out
    } finally { try { $bystander.Kill() } catch { } }

    # Malformed checks are a [FAIL] with the specific reason, never a silent absence:
    # a config that reads as enforcement and does nothing is the oldest defect in this
    # file. Trusted first, so the verdict cannot be standing on the trust gate instead.
    foreach ($case in @(
            @{ Json = '{"checks":[{"name":"Bad Name","run":"exit 0"}]}'; Match = 'no usable name' },
            @{ Json = '{"checks":[{"name":"a","run":"exit 0"},{"name":"a","run":"exit 0"}]}'; Match = "two checks named 'a'" },
            @{ Json = '{"checks":[{"name":"a"}]}'; Match = 'needs a non-empty' },
            @{ Json = '{"checks":[{"name":"a","run":"exit 0","level":"sometimes"}]}'; Match = 'must be fast or full' },
            @{ Json = '{"checks":"not an array"}'; Match = 'must be an array' },
            @{ Json = '{"checks":[{"name":"s","smoke":{"exe":"x"}}]}'; Match = 'smoke needs a "stages" array' },
            @{ Json = '{"checks":[{"name":"s","run":"exit 0","smoke":{"exe":"x","stages":[{"name":"m","ready":"r"}]}}]}'; Match = 'both "run" and "smoke"' },
            @{ Json = '{"checks":[{"name":"s","level":"fast","smoke":{"exe":"x","stages":[{"name":"m","ready":"r"}]}}]}'; Match = 'its level can only be full' })) {
        [IO.File]::WriteAllText($custJson, $case.Json)
        Invoke-Trust $cust | Out-Null
        $r = Invoke-Gate $cust
        Check "malformed checks fail with the reason: $($case.Match)" `
            (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] custom') -and ($r.Out -match [regex]::Escape($case.Match))) $r.Out
    }

    # Smoke checks (gate/smoke.ps1): the gate launches the app a check declares, waits for
    # each stage's ready line, captures the window, closes it and reads the log. The app
    # is testdata/smoke-fixture/app.ps1, a small WinForms window placed off-screen -- no
    # real game is ever launched here: it would cover the desktop and can touch real saves.
    if ($IsWindows) {
        $fx = Join-Path $PSScriptRoot 'testdata\smoke-fixture\app.ps1'
        function Invoke-Smoke([string]$Mode, [hashtable]$Extra = @{}, [int]$Timeout = 60, [string]$Color = 'SeaGreen', $Stages, [array]$Before = @()) {
            if (-not $Stages) { $Stages = @(@{ name = 'menu'; ready = 'Starting menu'; holdSec = 1 }, @{ name = 'world'; ready = 'Spawned in world'; holdSec = 1 }) }
            $smoke = @{ exe = 'pwsh'; args = @('-NoProfile', '-File', $fx, $Mode, '{dataDir}', $Color); log = '{dataDir}/app.log'; stages = $Stages }
            foreach ($k in $Extra.Keys) { $smoke[$k] = $Extra[$k] }
            [IO.File]::WriteAllText($custJson, (@{ checks = @($Before + @{ name = 'smoke'; timeoutSec = $Timeout; smoke = $smoke }) } | ConvertTo-Json -Depth 10))
            Invoke-Trust $cust | Out-Null
            $o = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cust -All -Only 'custom' -Full 2>&1 | Out-String)
            [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
        }

        $r = Invoke-Smoke 'pass'
        $runDir = if ($r.Out -match '\[PASS\] smoke -- 2 screenshot\(s\) in (\S+) \(') { $Matches[1] } else { '' }
        Check 'a smoke check that reaches every stage passes and names its screenshots' `
            (($r.Code -eq 0) -and $runDir -and ($r.Out -notmatch 'LEAK')) $r.Out
        Check 'smoke captures the main window at each stage as a PNG' `
            ($runDir -and @('menu', 'world' | Where-Object {
                        $f = Join-Path $runDir "$_.png"
                        (Test-Path $f) -and ([IO.File]::ReadAllBytes($f)[1..3] -join ',') -eq '80,78,71' }).Count -eq 2) $r.Out
        # #27: the app's writes land in the per-run dir the gate handed out, through both
        # channels (the {dataDir} argument and QGATE_DATA_DIR), and nowhere near the repo.
        $save = if ($runDir) { Join-Path $runDir 'data\save.dat' } else { '' }
        Check 'smoke hands the app an isolated per-run data dir ({dataDir} and QGATE_DATA_DIR)' `
            ($save -and (Test-Path $save) -and ((Get-Content $save -Raw).Trim() -eq "env=$(Join-Path $runDir 'data')") -and
                -not (Test-Path (Join-Path $cust '{dataDir}'))) "$save $($r.Out)"
        $r = Invoke-Gate $cust
        Check 'a smoke check is not run in the fast lane' `
            (($r.Code -eq 0) -and ($r.Out -match '\[SKIP\] smoke -- level full') -and ($r.Out -notmatch '\[PASS\] smoke')) $r.Out

        $r = Invoke-Smoke 'error'
        Check 'an exception in the smoke log fails with the line and its first frame' `
            (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] smoke') -and
                ($r.Out -match 'x1 NullReferenceException: boom \| at Fixture\.Hud\.Awake') -and ($r.Out -notmatch 'timeout|repeats')) $r.Out

        # #25: ignored once is noise, the same exception every frame is a stalled Update.
        $r = Invoke-Smoke 'repeat' @{ ignorePattern = 'tick'; repeatLimit = 3 }
        Check 'a repeating exception fails with its count even when ignorePattern covers it' `
            (($r.Code -ne 0) -and ($r.Out -match 'x\d+ \[repeats > 3\] NullReferenceException: tick \d+ \| at Fixture\.Chat\.HasFocus') -and
                ($r.Out -notmatch 'boom')) $r.Out

        $r = Invoke-Smoke 'hang' -Timeout 3
        Check 'a stage whose ready line never comes is a timeout, and the app is closed' `
            (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] smoke -- timeout after 3s') -and
                ($r.Out -match "stage 'menu': ready pattern /Starting menu/ never matched") -and ($r.Out -notmatch 'LEAK')) $r.Out

        $r = Invoke-Smoke 'crash'
        Check 'an app that exits before its first stage fails with its exit code, not as a timeout' `
            (($r.Code -ne 0) -and ($r.Out -match 'exited \(code 3\) before /Starting menu/') -and ($r.Out -notmatch 'timeout after')) $r.Out

        # #23: a baseline turns the screenshot into a check. Missing is a FAIL that says how
        # to accept the screen; after accepting, the same screen passes and a changed one fails.
        $bStages = @(@{ name = 'menu'; ready = 'Starting menu'; holdSec = 1; baseline = 'base/menu.png' })
        $r = Invoke-Smoke 'pass' -Stages $bStages
        $accept = if ($r.Out -match "to accept this screen: Copy-Item '([^']+)' '([^']+)'") { @($Matches[1], $Matches[2]) } else { @() }
        Check 'a declared baseline that does not exist fails and says how to accept the screen' `
            (($r.Code -ne 0) -and $accept.Count -eq 2) $r.Out
        if ($accept.Count -eq 2) {
            New-Item -ItemType Directory -Path (Split-Path $accept[1]) -Force | Out-Null
            Copy-Item $accept[0] $accept[1]
        }
        $r = Invoke-Smoke 'pass' -Stages $bStages
        Check 'a screenshot matching its baseline passes' ($r.Code -eq 0) $r.Out
        $r = Invoke-Smoke 'pass' -Stages $bStages -Color 'Blue'
        Check 'a screenshot that differs from its baseline fails with the ratio and tolerance' `
            (($r.Code -ne 0) -and ($r.Out -match "stage 'menu': screenshot differs from baseline by [\d.]+% \(tolerance 1%\)")) $r.Out

        # #28: a failed build/deploy before the smoke check must not launch the app on the
        # stale artifacts it left. Same repo + check name = same run dir; the smoke check
        # wipes and recreates it on launch, so its absence proves the app never started.
        if ($runDir) { Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue }
        $r = Invoke-Smoke 'pass' -Before @(@{ name = 'deploy-driver'; run = 'exit 1' })
        Check 'a smoke check after a failed check is skipped and the app is not launched' `
            (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] deploy-driver') -and
                ($r.Out -match '\[SKIP\] smoke -- not run: an earlier check failed') -and $runDir -and -not (Test-Path $runDir)) $r.Out
    }

    # ...and the two shapes that are simply absence, or every repository that pins a
    # tool version would grow a stack it never asked for.
    [IO.File]::WriteAllText($custJson, '{"tools":{"go":"1.0.0"},"checks":[]}')
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cust -All -Why 2>&1 | Out-String)
    Check 'an empty checks array is no stack at all' `
        (($out -match '\[WHY\] custom -- absent') -and ($out -notmatch '\[FAIL\] custom')) $out

    # QGATE_HOME: the state directory moves off the system drive, so reinstalling the
    # machine does not take what it trusts with it. Redirected here for the same reason
    # LOCALAPPDATA above is.
    $priorQHome = $env:QGATE_HOME
    try {
        [IO.File]::WriteAllText($custJson, '{"checks":[{"name":"quick","run":"exit 0","level":"fast"}]}')
        $legacyStore = Join-Path $env:LOCALAPPDATA 'qgate\trusted.json'
        $env:QGATE_HOME = $null
        $t = Invoke-Trust $cust
        Check 'without QGATE_HOME the trust store stays at the platform default' `
            ($t -match [regex]::Escape($legacyStore)) $t

        # An empty new store is not a neutral starting point: every repository trusted
        # yesterday silently stops running its own checks, and a phase that stopped
        # running reads exactly like a phase that passed. So the legacy file is copied
        # across on first use, and said out loud.
        $qh = Join-Path $tmp 'qgatehome'
        New-Item -ItemType Directory -Path $qh | Out-Null
        $env:QGATE_HOME = $qh
        $newStore = Join-Path $qh 'trusted.json'
        $r = Invoke-Gate $cust
        Check 'a QGATE_HOME with no store yet inherits the legacy one instead of dropping the trust' `
            ((Test-Path $newStore) -and
                ((Get-Content $newStore -Raw) -eq (Get-Content $legacyStore -Raw)) -and
                ($r.Out -match 'copied the trust store') -and ($r.Out -match '\[PASS\] quick')) $r.Out

        # ...and from there on QGATE_HOME is the store, not a copy nobody writes to.
        [IO.File]::WriteAllText($custJson,
            '{"checks":[{"name":"quick","run":"exit 0","level":"fast"},{"name":"moved","run":"exit 0","level":"fast"}]}')
        $t = Invoke-Trust $cust
        $r = Invoke-Gate $cust
        Check 'QGATE_HOME is where the trust store is read and written' `
            (($t -match [regex]::Escape($newStore)) -and ($r.Out -match '\[PASS\] moved') -and
                ((Get-Content $newStore -Raw) -ne (Get-Content $legacyStore -Raw))) "$t $($r.Out)"
    } finally { $env:QGATE_HOME = $priorQHome }
} finally { $env:LOCALAPPDATA = $priorLocal; $env:QGATE_HOME = $priorQGate }

# 35b. Deployed artifacts (quality-gate#26): qgate.json "deploy" compares the copy the
# host loads with the one this tree built, and a mismatch names WHICH cause it is --
# stale deploy, or the same source compiled in another directory (a deterministic build
# embeds the obj path, measured: 427 bytes of Auga.dll between two checkouts of one commit).
$dep = Join-Path $tmp 'deploy'
New-Item -ItemType Directory -Path (Join-Path $dep 'out'), (Join-Path $dep 'game') | Out-Null
[IO.File]::WriteAllText((Join-Path $dep 'qgate.json'), '{"deploy":[{"built":"out/Mod.dll","deployed":"game/Mod.dll"}]}')
function Invoke-DeployGate([switch]$Fast) {
    $a = @('-Root', $dep, '-Only', 'deploy'); if (-not $Fast) { $a += '-Full' }
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') @a 2>&1 | Out-String)
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}
# A real PE with a CodeView entry, so the directory diagnosis has a path to read.
$peSrc = Get-ChildItem $PSHOME -Filter *.dll | Where-Object Length -lt 200000 |
    Where-Object { [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($_.FullName)).Contains('.pdb') } | Select-Object -First 1
$peBytes = [IO.File]::ReadAllBytes($peSrc.FullName)
[IO.File]::WriteAllBytes((Join-Path $dep 'out\Mod.dll'), $peBytes)
[IO.File]::WriteAllBytes((Join-Path $dep 'game\Mod.dll'), $peBytes)
$r = Invoke-DeployGate
Check 'deploy: an identical deployed copy passes' (($r.Code -eq 0) -and ($r.Out -match '\[PASS\] deploy Mod\.dll')) $r.Out
$r = Invoke-DeployGate -Fast
Check 'deploy: the fast lane skips it without failing' `
    (($r.Code -eq 0) -and ($r.Out -match '\[SKIP\] deploy -- full level') -and ($r.Out -notmatch 'no check phase ran')) $r.Out
# Same bytes except one character of the embedded .pdb path: another checkout, same source.
$moved = [byte[]]$peBytes.Clone()
$at = [Text.Encoding]::ASCII.GetString($moved).IndexOf('.pdb') - 1
$moved[$at] = if ($moved[$at] -eq [byte][char]'X') { [byte][char]'Y' } else { [byte][char]'X' }
[IO.File]::WriteAllBytes((Join-Path $dep 'game\Mod.dll'), $moved)
$r = Invoke-DeployGate
Check 'deploy: a copy compiled in another directory fails and says so' `
    (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] deploy Mod\.dll') -and ($r.Out -match 'compiled in another directory') -and
        ($r.Out -notmatch 'newer than')) $r.Out
# An older deploy of different content: the plain stale case.
[IO.File]::WriteAllText((Join-Path $dep 'out\Mod.dll'), 'v2')
[IO.File]::WriteAllText((Join-Path $dep 'game\Mod.dll'), 'v1')
(Get-Item (Join-Path $dep 'game\Mod.dll')).LastWriteTime = (Get-Date).AddHours(-1)
$r = Invoke-DeployGate
Check 'deploy: a stale deployed copy fails with redeploy' `
    (($r.Code -ne 0) -and ($r.Out -match 'the build is newer than the deployed copy -- redeploy') -and
        ($r.Out -notmatch 'another directory')) $r.Out
# No deployed copy is a machine without the host (CI), not a finding.
Remove-Item (Join-Path $dep 'game\Mod.dll')
$r = Invoke-DeployGate
Check 'deploy: a machine without the deployed copy skips, not fails' `
    (($r.Code -eq 0) -and ($r.Out -match '\[SKIP\] deploy Mod\.dll -- not deployed on this machine')) $r.Out
[IO.File]::WriteAllText((Join-Path $dep 'qgate.json'), '{"deploy":[{"built":"out/Mod.dll"}]}')
$r = Invoke-DeployGate
Check 'deploy: a malformed entry fails with the reason' `
    (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] deploy') -and ($r.Out -match 'needs non-empty "built" and "deployed"')) $r.Out

}

if (Want 'cpp') {
# 36. The C/C++ CMake stack. Its two halves ask different tools -- clang-format for the
# format phase, cmake for configure and build -- and neither is on every machine, so
# every check here either asserts what the gate does WITHOUT the tool, or is guarded
# the way the gdtoolkit ones above are.
$cpp = Join-Path $tmp 'cpp'
Copy-Item (Join-Path $PSScriptRoot 'testdata\cpp-fixture') $cpp -Recurse
# A cmake run against this repository leaves testdata/cpp-fixture/build/ behind. It is
# gitignored, Copy-Item -Recurse does not care, and CMakeCache.txt records the ABSOLUTE
# path it was generated for -- so the copy failed `configure` with "the current
# CMakeCache.txt directory is different", on a fixture nobody had touched. Invisible
# until cmake was on PATH, which is the machine this suite is supposed to be honest on.
Remove-Item (Join-Path $cpp 'build') -Recurse -Force -ErrorAction SilentlyContinue

# A build tree is CMake's own output -- it carries a CMakeLists.txt for every
# dependency it fetched, and the next configure run deletes the lot. A CMakeLists.txt
# BELOW one that was already detected is add_subdirectory() material: the top one
# configures it too, so a second stack would configure and build the same code twice.
$cppTree = Join-Path $tmp 'cpp-tree'
foreach ($sub in '', 'build', 'out', '_deps', 'cmake-build-debug', 'src\engine') {
    $d = if ($sub) { Join-Path $cppTree $sub } else { $cppTree }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Set-Content (Join-Path $d 'CMakeLists.txt') 'project(x)'
}
$cppStacks = @(Get-Stacks $cppTree | Where-Object { $_.Stack -eq 'cpp' })
Check 'only the topmost CMakeLists.txt of a tree is a stack' `
    (($cppStacks.Count -eq 1) -and ($cppStacks[0].Rel -eq '')) `
    (($cppStacks | ForEach-Object { "cpp '$($_.Rel)'" }) -join ' | ')
# ...and "topmost per TREE" is not "one per repository". Without this half, a rule that
# detected nothing at all below the root would satisfy the check above.
$cppTwo = Join-Path $tmp 'cpp-two'
foreach ($sub in 'a', 'b') {
    New-Item -ItemType Directory -Path (Join-Path $cppTwo $sub) -Force | Out-Null
    Set-Content (Join-Path $cppTwo "$sub\CMakeLists.txt") 'project(x)'
}
$cppRels = @(Get-Stacks $cppTwo | Where-Object { $_.Stack -eq 'cpp' }).Rel
Check 'two sibling CMake projects are two stacks' `
    ((($cppRels | Sort-Object) -join ',') -eq 'a,b') "got: $($cppRels -join ',')"

# No .clang-format: the gate has no style to check the sources against, and it neither
# invents one nor stays quiet about the phase it therefore did not run.
$r = Invoke-Gate $cpp
Check 'format is skipped when there is no .clang-format' `
    ($r.Out -match '\[SKIP\] format -- no \.clang-format') $r.Out

$out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cpp -Only cpp 2>&1 | Out-String)
Check '-Only cpp selects the stack' `
    (($out -notmatch 'no such stack detected') -and ($out -match 'cpp \(CMakeLists\.txt\)')) $out

Set-Content (Join-Path $cpp '.clang-format') 'BasedOnStyle: LLVM'
[IO.File]::WriteAllText((Join-Path $cpp 'src\ugly.cpp'), "int  ugly( ) {return    0;}`n")
$r = Invoke-Gate $cpp
if (Get-Command clang-format -ErrorAction SilentlyContinue) {
    Check 'clang-format fails the gate on a misformatted source' `
        (($r.Code -ne 0) -and ($r.Out -match '\[FAIL\] format') -and ($r.Out -match 'ugly\.cpp')) $r.Out
} else {
    # Nothing was checked, and "not checked" must never read as "clean" -- the same
    # rule the [UNKNOWN] lines elsewhere in this gate exist for.
    Check 'a missing clang-format is named, not silently passed' `
        ($r.Out -match '\[SKIP\] format -- clang-format not found') $r.Out
}
# It has served its purpose, and every later run over this fixture is about something
# else -- a stack the gate selects, a tool it cannot find. Left in place, on a machine
# that HAS clang-format those runs came back `[FAIL] format` and the checks below read
# a red report for a question they never asked.
Remove-Item (Join-Path $cpp 'src\ugly.cpp') -Force

# cmake is on this machine or it is not, and the gate's answer has to be the same
# either way -- so it is hidden from PATH for the two runs below instead of the suite
# skipping itself on half the machines. Same split the .NET SDK and the Godot binary
# follow: the full level is what guards a commit and CI, so it fails there; the fast
# lane never reaches configure or build, so it only warns.
$priorPath = $env:PATH
$sep = [IO.Path]::PathSeparator
$env:PATH = @($priorPath -split $sep | Where-Object {
        $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'cmake.exe') -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath (Join-Path $_ 'cmake') -ErrorAction SilentlyContinue)
    }) -join $sep
try {
    $fast = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cpp -All 2>&1 | Out-String)
    $full = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cpp -All -Full 2>&1 | Out-String)
    $fullCode = $LASTEXITCODE
    Check 'no cmake warns on the fast level, it does not fail there' `
        (($fast -match '\[WARN\] cpp .*cmake not on PATH') -and ($fast -notmatch 'required at the full level')) $fast
    Check 'no cmake fails the full level, with the reason' `
        (($fullCode -ne 0) -and ($full -match 'cmake not on PATH -- required at the full level')) $full
} finally { $env:PATH = $priorPath }

# The two static-analysis phases read their file list out of a compile database, which
# is CMake's answer: it names every translation unit the BUILD compiles, dependencies
# included, and the findings arrive from wherever the preprocessor reached. Both
# conditions of the filter, because either alone lets one of those through -- measured
# on a real repository, half the cppcheck findings came out of SDK headers two
# directories above the project.
$owner = Join-Path $tmp 'cpp'
Check 'the stack own sources are what the analysis phases see' `
    ((Test-CppOwn (Join-Path $owner 'src\greeting.cpp') $owner) -and
    (Test-CppOwn (($owner -replace '\\', '/') + '/src/greeting.cpp') $owner))
Check 'build trees and paths outside the stack are not analysed' `
    (-not ((Test-CppOwn (Join-Path $owner 'build\_deps\zlib\z.c') $owner) -or
        (Test-CppOwn (Join-Path $owner '_deps\zlib\z.c') $owner) -or
        (Test-CppOwn (Join-Path $tmp 'elsewhere\sdk\ngx.h') $owner)))

# A clean copy: the fixture above now carries a .clang-format and a deliberately
# misformatted source, and a failed format phase would leave every phase after it
# reporting "not run" -- which is not what these checks are about.
$cppAn = Join-Path $tmp 'cpp-analysis'
Copy-Item (Join-Path $PSScriptRoot 'testdata\cpp-fixture') $cppAn -Recurse
Remove-Item (Join-Path $cppAn 'build') -Recurse -Force -ErrorAction SilentlyContinue
# bugprone-incorrect-roundings in the stack's own source, bugprone-branch-clone in a
# dependency the build compiles: one has to be reported and the other has to not be.
[IO.File]::WriteAllText((Join-Path $cppAn 'src\rounding.cpp'), "int qgate_round(double x) { return (int)(x + 0.5); }`n")
New-Item -ItemType Directory -Path (Join-Path $cppAn '_deps\vendor') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $cppAn '_deps\vendor\vendor.cpp'), "int qgate_pick(int c) { if (c) { return 7; } else { return 7; } }`n")
# Leading newline: the fixture's last line has none, and cmake answers an appended
# command with `Parse error. Expected a newline`.
Add-Content (Join-Path $cppAn 'CMakeLists.txt') "`ntarget_sources(qgate_fixture PRIVATE src/rounding.cpp _deps/vendor/vendor.cpp)"

# Neither phase runs on the fast lane. They cost tens of seconds on a real tree (26.7s
# for clang-tidy over 22 translation units), and a fast lane that pays that on every
# commit is a fast lane people stop running -- the same split configure and build take.
$r = Invoke-Gate $cppAn
Check 'tidy and cppcheck are full-level only' `
    (($r.Out -notmatch '\btidy\b') -and ($r.Out -notmatch '\bcppcheck\b')) $r.Out

# Neither tool is on every machine, and "not checked" must never read as "clean".
$priorPath = $env:PATH
$env:PATH = @($priorPath -split $sep | Where-Object {
        $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'clang-tidy.exe') -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath (Join-Path $_ 'clang-tidy') -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath (Join-Path $_ 'cppcheck.exe') -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath (Join-Path $_ 'cppcheck') -ErrorAction SilentlyContinue)
    }) -join $sep
try {
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cppAn -All -Full 2>&1 | Out-String)
    Check 'a missing clang-tidy is named, not silently passed' `
        ($out -match '\[SKIP\] tidy -- clang-tidy not found') $out
    Check 'a missing cppcheck is named, not silently passed' `
        ($out -match '\[SKIP\] cppcheck -- cppcheck not found') $out
} finally { $env:PATH = $priorPath }

# The findings themselves, where the tools exist. clang-tidy needs a compile database,
# and on Windows the default generator is a Visual Studio one, which ignores
# CMAKE_EXPORT_COMPILE_COMMANDS -- the gate configures a throwaway Ninja tree with
# clang-cl to get one, so this needs those two as well.
$cdbOk = (Get-Command ninja -ErrorAction SilentlyContinue) -and (Get-Command clang-cl -ErrorAction SilentlyContinue)
if ((Get-Command clang-tidy -ErrorAction SilentlyContinue) -and ($cdbOk -or -not $IsWindows)) {
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $cppAn -All -Full 2>&1 | Out-String)
    $code = $LASTEXITCODE
    # First pass over these repositories, exactly as the Roslyn analyzers got in 379f39d:
    # the volume is reported and nothing goes red on it. A rule that fails a commit
    # before anybody has read it is a rule people route around.
    Check 'clang-tidy findings warn, they do not fail the phase' `
        (($code -eq 0) -and ($out -match '\[WARN\] tidy: \d+ finding\(s\).*bugprone-incorrect-roundings') -and
        ($out -match '\[PASS\] tidy')) "code=$code $out"
    # ...and the dependency's own defect is the build's business, not this repository's.
    Check 'a _deps source the build compiles is not analysed' `
        ($out -notmatch 'bugprone-branch-clone') $out
}

}

if (Want 'base') {
# 37. The base stack: the one with no marker file. Every git work tree has it, all
# three of its tools are optional external binaries, and none of them is on every
# machine -- so every check here either strips the tools from PATH itself or asserts
# something true whether or not they are installed.
$baseRepo = Join-Path $tmp 'base'
New-Item -ItemType Directory -Path $baseRepo | Out-Null
git -C $baseRepo init -q 2>$null
$baseStacks = @(Get-Stacks $baseRepo)
# Both halves: base is there with no marker file of any kind, and it is the ONLY
# thing there -- "detects every stack everywhere" would satisfy the first half alone.
Check 'base exists in a repo with no marker file at all' `
    ((($baseStacks | ForEach-Object { $_.Stack }) -join ',') -eq 'base') `
    "got: $(($baseStacks | ForEach-Object { $_.Stack }) -join ',')"
# ...and the condition really is the work tree, not "always": a directory that is not
# a repository has no index for the fast secrets scan to read, and it is still the
# documented free pass that section 31 asserts.
$baseNoGit = Join-Path $tmp 'base-nogit'
New-Item -ItemType Directory -Path $baseNoGit | Out-Null
Check 'base does not exist outside a git work tree' `
    (-not (@(Get-Stacks $baseNoGit) | Where-Object { $_.Stack -eq 'base' }))

$gate = Join-Path $PSScriptRoot 'gate\check.ps1'
$out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String)
$baseOnlyCode = $LASTEXITCODE
Check '-Only base selects the stack' `
    (($out -notmatch 'no such stack detected') -and ($out -match 'base \(git work tree\)')) $out
# ...and a machine with none of the three tools must not turn every repository on it
# into one nobody can commit to. base has no marker file, so it is in EVERY run: the
# zero-phase invariant is exempted only when base was the whole run.
Check 'base alone with nothing to run is not a failed run' ($baseOnlyCode -eq 0) "code=$baseOnlyCode $out"

# ...but -Only cpp must not drag it along. The cpp fixture is made a work tree first,
# or the absence proved here would only be the absence of a git repository.
git -C $cpp init -q 2>$null
$out = (& pwsh -NoProfile -File $gate -Root $cpp -Only cpp 2>&1 | Out-String)
Check '-Only cpp does not run base' (($out -match 'cpp \(CMakeLists\.txt\)') -and ($out -notmatch 'base')) $out

# Each phase names the tool it is missing. Stripped from PATH here rather than skipped
# on half the machines: "the tool is absent" is the gate's answer, and it has to be the
# same answer everywhere. A [SKIP] carrying the name, never a [FAIL] -- the gate does
# not install toolchains.
$priorPath = $env:PATH
$sep = [IO.Path]::PathSeparator
$env:PATH = @($priorPath -split $sep | Where-Object {
        $d = $_
        $d -and -not (@('gitleaks', 'typos', 'osv-scanner') | Where-Object {
                (Test-Path -LiteralPath (Join-Path $d "$_.exe") -ErrorAction SilentlyContinue) -or
                (Test-Path -LiteralPath (Join-Path $d $_) -ErrorAction SilentlyContinue) })
    }) -join $sep
try {
    $out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String)
    $noToolCode = $LASTEXITCODE
    Check 'a missing gitleaks is named, not silently passed' `
        ($out -match '\[SKIP\] secrets -- gitleaks not on PATH') $out
    Check 'a missing typos is named, not silently passed' `
        ($out -match '\[SKIP\] typos -- typos not on PATH') $out
    Check 'a missing osv-scanner is named, not silently passed' `
        ($out -match '\[SKIP\] vuln -- osv-scanner not on PATH') $out
    Check 'an absent optional tool is a skip, not a failed run' `
        (($noToolCode -eq 0) -and ($out -notmatch '\[FAIL\]')) "code=$noToolCode $out"

    # #82: qgate.deferrals.json "vulnerabilities" acknowledges an advisory with no fix, by
    # id or alias, with an expiry. Both sides: everything acknowledged passes and names each
    # acknowledgement; a new id, an expired entry or an invalid one still fails.
    $osvShim = Join-Path $tmp 'osv-shim'
    New-VulnShim $osvShim 'osv-scanner' '--format json' `
        '{"results":[{"packages":[{"groups":[{"ids":["GHSA-q7pp-wcgr-pffx"],"aliases":["GHSA-q7pp-wcgr-pffx","CVE-2026-0001"]}]}]},{"packages":[{"groups":[{"ids":["GO-2026-5932"],"aliases":["GO-2026-5932"]}]}]}]}' `
        'shimtable GHSA-q7pp-wcgr-pffx GO-2026-5932' 1
    $env:PATH = "$osvShim$sep$env:PATH"
    $ackFile = Join-Path $baseRepo 'qgate.deferrals.json'
    $ack = { param($Entries) [IO.File]::WriteAllText($ackFile, (@{ vulnerabilities = $Entries } | ConvertTo-Json -Depth 5)) }
    & $ack @(@{ id = 'CVE-2026-0001'; until = '2099-01-01'; reason = 'no fixed version' }, @{ id = 'GO-2026-5932'; until = '2099-01-01'; reason = 'latest release' })
    $out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String); $code = $LASTEXITCODE
    Check 'vuln: every advisory acknowledged (one by alias) passes and names each one' `
        (($code -eq 0) -and ($out -match '\[PASS\] vuln') -and ($out -notmatch '\[FAIL\]') -and
        ($out -match '\[WARN\] qgate\.deferrals\.json: vuln CVE-2026-0001 acknowledged until 2099-01-01 -- no fixed version') -and
        ($out -match '\[WARN\] qgate\.deferrals\.json: vuln GO-2026-5932 acknowledged until 2099-01-01 -- latest release')) "code=$code $out"
    $out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full -Quiet 2>&1 | Out-String)
    Check 'vuln: an acknowledgement is printed under -Quiet too' ($out -match 'vuln GO-2026-5932 acknowledged until') $out
    & $ack @(@{ id = 'GO-2026-5932'; until = '2099-01-01'; reason = 'latest release' })
    $out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String); $code = $LASTEXITCODE
    Check 'vuln: an unacknowledged advisory beside an acknowledged one still fails, named' `
        (($code -ne 0) -and ($out -match '\[FAIL\] vuln') -and ($out -match 'not acknowledged: GHSA-q7pp-wcgr-pffx') -and
        ($out -notmatch 'not acknowledged: GO-2026-5932') -and ($out -match 'shimtable')) "code=$code $out"
    & $ack @(@{ id = 'GHSA-q7pp-wcgr-pffx'; until = '2020-01-01'; reason = 'waiting upstream' }, @{ id = 'GO-2026-5932'; until = '2099-01-01'; reason = 'latest release' })
    $out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String); $code = $LASTEXITCODE
    Check 'vuln: an expired acknowledgement fails, and says it expired' `
        (($code -ne 0) -and ($out -match 'acknowledgement expired: GHSA-q7pp-wcgr-pffx was acknowledged until 2020-01-01') -and
        ($out -notmatch 'not acknowledged: GHSA')) "code=$code $out"
    & $ack @(@{ id = 'GHSA-q7pp-wcgr-pffx'; reason = 'no until' }, @{ id = 'GO-2026-5932'; until = '2099-01-01'; reason = 'latest release' })
    $out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String); $code = $LASTEXITCODE
    Check 'vuln: an acknowledgement without until is invalid, warned once, and acknowledges nothing' `
        (($code -ne 0) -and ($out -match 'not acknowledged: GHSA-q7pp-wcgr-pffx') -and
        ([regex]::Matches($out, "\[WARN\] qgate\.deferrals\.json vulnerabilities entry for 'GHSA-q7pp-wcgr-pffx' needs 'until'").Count -eq 1)) "code=$code $out"
    Remove-Item $ackFile
    $out = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String); $code = $LASTEXITCODE
    Check 'vuln: with no acknowledgements the findings fail as before' `
        (($code -ne 0) -and ($out -match '\[FAIL\] vuln') -and ($out -match 'shimtable') -and ($out -notmatch 'acknowledg')) "code=$code $out"
} finally { $env:PATH = $priorPath }

# The advisory file-kind linters (#53-#58): skipped by name when absent, [WARN] and never
# [FAIL] when they find something, silent when they do not. The tools are stood in for by
# shims that exit 1 or 0, so every machine judges the gate's handling, not the tool.
$lintExes = @('shellcheck', 'actionlint', 'hadolint', 'markdownlint-cli2', 'yamllint', 'editorconfig-checker')
$lint = Join-Path $tmp 'base-lint'
New-Item -ItemType Directory -Path (Join-Path $lint '.github\workflows') -Force | Out-Null
git -C $lint init -q 2>$null
foreach ($f in @('run.sh', '.github/workflows/ci.yml', 'Dockerfile', 'notes.md', '.editorconfig')) {
    [IO.File]::WriteAllText((Join-Path $lint $f), "root = true`n")
}
git -C $lint add -A 2>$null
$env:PATH = @($priorPath -split $sep | Where-Object {
        $d = $_
        $d -and -not ($lintExes | Where-Object {
                (Test-Path -LiteralPath (Join-Path $d "$_.exe") -ErrorAction SilentlyContinue) -or
                (Test-Path -LiteralPath (Join-Path $d "$_.cmd") -ErrorAction SilentlyContinue) -or
                (Test-Path -LiteralPath (Join-Path $d $_) -ErrorAction SilentlyContinue) })
    }) -join $sep
$strippedPath = $env:PATH
try {
    $out = (& pwsh -NoProfile -File $gate -Root $lint -Only base -Full 2>&1 | Out-String)
    Check 'a missing file-kind linter is a named skip, not a failed run' `
        (($LASTEXITCODE -eq 0) -and ($out -notmatch '\[FAIL\]') -and
        -not ($lintExes | Where-Object { $out -notmatch "\[SKIP\] .* -- $([regex]::Escape($_)) not on PATH" })) $out
    foreach ($exit in 1, 0, 2) {
        $shim = Join-Path $tmp "lint-shim-$exit"
        New-Item -ItemType Directory -Path $shim -Force | Out-Null
        foreach ($e in $lintExes) {
            if ($IsWindows) { [IO.File]::WriteAllText((Join-Path $shim "$e.cmd"), "@echo shimfinding %*`r`n@exit /b $exit`r`n") }
            else {
                $p = Join-Path $shim $e
                [IO.File]::WriteAllText($p, "#!/bin/sh`necho shimfinding `"`$@`"`nexit $exit`n")
                chmod +x $p
            }
        }
        # #73: npm installs markdownlint-cli2 as a .ps1 shim too, and PowerShell prefers it. That
        # shim joined array arguments into one string; counting args proves each path arrives alone.
        if ($IsWindows) { [IO.File]::WriteAllText((Join-Path $shim 'markdownlint-cli2.ps1'), "`"shimfinding args=`$(`$args.Count)`"; exit $exit`n") }
        $env:PATH = "$shim$sep$strippedPath"
        $out = (& pwsh -NoProfile -File $gate -Root $lint -Only base -Full 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($exit -eq 1) {
            Check 'file-kind linter findings are [WARN], never [FAIL]' `
                (($code -eq 0) -and ($out -notmatch '\[FAIL\]') -and
                ([regex]::Matches($out, '\[WARN\] (shellcheck|actionlint|hadolint|markdownlint|yamllint|editorconfig):').Count -eq 6)) "code=$code $out"
            # A green stack line drops its detail lines; the findings are report-level.
            Check 'file-kind linter findings are printed, not just counted' ($out -match 'shimfinding') $out
            # An LF script in the index is not a literal-CR defect, whatever the checkout wrote.
            Check 'shellcheck skips SC1017 for a script the index holds LF' ($out -match 'shimfinding -f gcc -e SC1017') $out
            if ($IsWindows) { Check 'markdownlint gets each argument separately through a .ps1 shim (#73)' ($out -match 'shimfinding args=3') $out }
            $fastOut = (& pwsh -NoProfile -File $gate -Root $lint -Only base 2>&1 | Out-String)
            Check 'the fast lane lints the changed files' `
                ([regex]::Matches($fastOut, '\[WARN\] (shellcheck|actionlint|hadolint|markdownlint|yamllint|editorconfig):').Count -eq 6) $fastOut
        } elseif ($exit -eq 2) {
            # #73: a linter that crashed checked nothing -- [UNKNOWN], never advisory findings.
            Check 'a crashed file-kind linter is [UNKNOWN], not [WARN] findings' `
                (($code -eq 0) -and ($out -notmatch '\[WARN\] (shellcheck|actionlint|hadolint|markdownlint|yamllint|editorconfig):') -and
                ([regex]::Matches($out, '\[UNKNOWN\] (shellcheck|actionlint|hadolint|markdownlint|yamllint|editorconfig): could not lint').Count -eq 6)) "code=$code $out"
        } else {
            Check 'a clean file-kind linter prints nothing' (($code -eq 0) -and ($out -notmatch 'shimfinding')) "code=$code $out"
        }
    }
} finally { $env:PATH = $priorPath }

# #50: gremlins runs only under -Mutate. A stand-in that leaves a marker proves the default
# run never invokes it; a missing tool is a [SKIP]; survivors are a [WARN], exit 0.
$mut = Join-Path $tmp 'mutate'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $mut -Recurse
$mutShim = Join-Path $tmp 'gremlins-shim'
New-Item -ItemType Directory -Path $mutShim -Force | Out-Null
$mutMark = Join-Path $tmp 'gremlins-invoked'
$lived = 'LIVED CONDITIONALS_BOUNDARY at main.go:6:35'
if ($IsWindows) { [IO.File]::WriteAllText((Join-Path $mutShim 'gremlins.cmd'), "@echo x> `"$mutMark`"`r`n@echo        $lived`r`n@echo Killed: 1, Lived: 1, Not covered: 0`r`n@exit /b 0`r`n") }
else {
    $p = Join-Path $mutShim 'gremlins'
    [IO.File]::WriteAllText($p, "#!/bin/sh`necho x > '$mutMark'`necho '       $lived'`necho 'Killed: 1, Lived: 1, Not covered: 0'`n")
    chmod +x $p
}
$noGremlins = @($priorPath -split $sep | Where-Object { $_ -and -not (Get-ChildItem -LiteralPath $_ -Filter 'gremlins*' -ErrorAction SilentlyContinue) }) -join $sep
try {
    $env:PATH = "$mutShim$sep$noGremlins"
    $out = (& pwsh -NoProfile -File $gate -Root $mut -All -Only go 2>&1 | Out-String)
    Check 'without -Mutate gremlins is never invoked' (($LASTEXITCODE -eq 0) -and -not (Test-Path $mutMark) -and ($out -notmatch 'gremlins')) $out
    $out = (& pwsh -NoProfile -File $gate -Root $mut -All -Only go -Mutate 2>&1 | Out-String)
    $code = $LASTEXITCODE
    Check 'surviving mutants are a [WARN] under -Mutate, exit 0' `
        (($code -eq 0) -and ($out -match '\[WARN\] gremlins: 1 surviving mutant') -and ($out -match [regex]::Escape($lived)) -and ($out -notmatch '\[FAIL\]')) "code=$code $out"
    $env:PATH = $noGremlins
    $out = (& pwsh -NoProfile -File $gate -Root $mut -All -Only go -Mutate 2>&1 | Out-String)
    $code = $LASTEXITCODE
    Check 'a missing gremlins is a [SKIP] with an install hint, exit 0' `
        (($code -eq 0) -and ($out -match '\[SKIP\] gremlins -- not on PATH \(go install github.com/go-gremlins')) "code=$code $out"

    # #59: -Sarif is opt-in. Without it no file appears and stdout is the plain report;
    # with it stdout is byte-identical and the file is SARIF 2.1.0: [WARN] -> warning,
    # [FAIL] -> error, and a compiler's `path:line:col` line carries a physical location.
    $sarifFile = Join-Path $tmp 'qgate.sarif'
    $env:PATH = "$mutShim$sep$noGremlins"
    $plain = (& pwsh -NoProfile -File $gate -Root $mut -All -Only go -Mutate 2>&1 | Out-String)
    Check 'without -Sarif no SARIF file is written' (-not (Test-Path $sarifFile)) $plain
    $out = (& pwsh -NoProfile -File $gate -Root $mut -All -Only go -Mutate -Sarif $sarifFile 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $doc = try { Get-Content $sarifFile -Raw | ConvertFrom-Json } catch { $null }
    $mutWarn = @($doc.runs[0].results | Where-Object { $_.level -eq 'warning' -and $_.message.text -match 'surviving mutant' })
    Check '-Sarif keeps stdout and exit code, writes valid 2.1.0 with [WARN] as warning' `
        (($code -eq 0) -and (($out -replace '\(\d+\.\d+s\)', '') -eq ($plain -replace '\(\d+\.\d+s\)', '')) -and $doc -and ($doc.version -eq '2.1.0') -and ($doc.'$schema' -match 'sarif-2\.1\.0') -and
         ($doc.runs[0].tool.driver.name -eq 'quality-gate') -and $mutWarn.Count -eq 1 -and -not @($doc.runs[0].results | Where-Object level -eq 'error')) "code=$code $out"
    Set-GoFile (Join-Path $mut 'main.go') "package main`n`nfunc main() { undefinedName() }"
    $out = (& pwsh -NoProfile -File $gate -Root $mut -All -Only go -Sarif $sarifFile 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $doc = try { Get-Content $sarifFile -Raw | ConvertFrom-Json } catch { $null }
    $errs = @($doc.runs[0].results | Where-Object level -eq 'error')
    $located = @($errs | Where-Object { $_.locations -and $_.locations[0].physicalLocation.artifactLocation.uri -match 'main\.go$' -and $_.locations[0].physicalLocation.region.startLine -eq 3 })
    Check '-Sarif maps [FAIL] to error and a path:line:col line to a location' `
        (($code -eq 1) -and ($out -match '\[FAIL\]') -and $errs.Count -ge 1 -and $located.Count -ge 1) "code=$code $out $(Get-Content $sarifFile -Raw -ErrorAction SilentlyContinue)"
} finally { $env:PATH = $priorPath }

# #61: -Parallel is opt-in and changes wall-clock only. Two independent stacks (go, web)
# run as child processes; the report must be the sequential one line for line (timings
# aside) with the same exit code -- green, a red web stack, and a red go stack whose
# later web stack is still reported as not run although its child did run it.
$par = Join-Path $tmp 'parallel'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') (Join-Path $par 'svc') -Recurse
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') (Join-Path $par 'ui') -Recurse
Remove-Item (Join-Path $par 'ui\node_modules') -Recurse -Force -ErrorAction SilentlyContinue
function Get-ParRun([string[]]$More) {
    $o = (& pwsh -NoProfile -File $gate -Root $par -All @More 2>&1 | Out-String)
    [pscustomobject]@{ Code = $LASTEXITCODE; Raw = $o; Norm = ($o -replace '\(\d+\.\d+s\)', '(t)').Trim() }
}
$parCases = @(
    @{ Name = 'a red web stack'; Setup = {}; Code = 1 },
    @{ Name = 'green'; Setup = {
            New-Item -ItemType Directory (Join-Path $par 'ui\node_modules\.bin') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $par 'ui\package.json'), '{ "name": "ui", "private": true }')
        }; Code = 0 },
    @{ Name = 'a red go stack before web'; Setup = { Set-GoFile (Join-Path $par 'svc\main.go') "package main`n`nfunc main() { undefinedName() }" }; Code = 1 }
)
foreach ($pc in $parCases) {
    & $pc.Setup
    $seq = Get-ParRun @()
    $pr = Get-ParRun @('-Parallel')
    Check "-Parallel reports what the sequential run does: $($pc.Name)" `
        (($seq.Code -eq $pc.Code) -and ($pr.Code -eq $seq.Code) -and ($pr.Norm -eq $seq.Norm) -and ($seq.Norm -match '\[(PASS|FAIL)\] go svc/') -and ($seq.Norm -match 'web ui/')) "seq=$($seq.Code) par=$($pr.Code)`n$($seq.Raw)`n---`n$($pr.Raw)"
}
Check '-Parallel red go stack still reports web as not run' ($pr.Norm -match '\[SKIP\] web ui/ .* an earlier stack failed') $pr.Raw

# The vulnerability database lives on the network, so vuln is full-level only -- the
# same rule govulncheck and `npm audit` follow. Asserted on the LINE, not on a verdict:
# whether it passes, skips for a missing binary or skips for an osv-scanner v1 that has
# no `scan source`, the full level says something about vuln and the fast lane does not.
$fast = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base 2>&1 | Out-String)
$full = (& pwsh -NoProfile -File $gate -Root $baseRepo -Only base -Full 2>&1 | Out-String)
Check 'vuln does not run on the fast lane' ($fast -notmatch 'vuln') $fast
Check 'vuln runs at the full level' ($full -match 'vuln') $full

# typos scopes itself the way every other fast phase does: the whole tree at the full
# level, only what git says changed on the fast lane. Both halves, because "never
# reports anything" would satisfy the fast one on its own.
if (Get-Command typos -ErrorAction SilentlyContinue) {
    $ty = Join-Path $tmp 'typos'
    New-Item -ItemType Directory -Path $ty | Out-Null
    git -C $ty init -q 2>$null
    # Assembled from two halves so the misspelling is never a literal in this file:
    # written out whole it is a real finding in THIS repository, and the gate's own
    # base stack fails on its own test fixture. Silencing it in _typos.toml instead
    # would switch off the word everywhere, which is the opposite of the point.
    $typo = 'rec' + 'ieve'
    [IO.File]::WriteAllText((Join-Path $ty 'committed.txt'), "you will $typo this line`n")
    git -C $ty add -A 2>$null
    git -C $ty -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    [IO.File]::WriteAllText((Join-Path $ty 'touched.txt'), "this one is spelled correctly`n")
    $out = (& pwsh -NoProfile -File $gate -Root $ty -Only base 2>&1 | Out-String)
    $tyFastCode = $LASTEXITCODE
    Check 'typos on the fast lane judges only the changed files' `
        (($tyFastCode -eq 0) -and ($out -notmatch $typo)) "code=$tyFastCode $out"
    $out = (& pwsh -NoProfile -File $gate -Root $ty -Only base -Full 2>&1 | Out-String)
    $tyFullCode = $LASTEXITCODE
    Check 'typos at the full level judges the whole tree' `
        (($tyFullCode -ne 0) -and ($out -match '\[FAIL\] typos') -and ($out -match 'committed\.txt')) "code=$tyFullCode $out"

    # The invariant the scoping above cannot state on its own: the two lanes must
    # reach the SAME verdict about the same file. typos applies the repository's own
    # _typos.toml excludes when it walks the tree and ignores them for any path named
    # on the command line, so the fast lane -- which narrows to changed paths -- was
    # red on a file the full lane never looked at. Asked as an equality rather than as
    # "the flag is present", because any phase that narrows to changed paths can grow
    # this same divergence with a different tool.
    $tx = Join-Path $tmp 'typos-exclude'
    New-Item -ItemType Directory -Path (Join-Path $tx 'locale') -Force | Out-Null
    git -C $tx init -q 2>$null
    [IO.File]::WriteAllText((Join-Path $tx '_typos.toml'), "[files]`nextend-exclude = [`"locale/*.txt`"]`n")
    [IO.File]::WriteAllText((Join-Path $tx 'locale\fr.txt'), "you will $typo this line`n")
    $txFast = (& pwsh -NoProfile -File $gate -Root $tx -Only base 2>&1 | Out-String)
    $txFastCode = $LASTEXITCODE
    $txFull = (& pwsh -NoProfile -File $gate -Root $tx -Only base -Full 2>&1 | Out-String)
    $txFullCode = $LASTEXITCODE
    Check 'an excluded file gets the same typos verdict on the fast lane and the full one' `
        (($txFastCode -eq $txFullCode) -and ($txFastCode -eq 0) -and
            ($txFast -notmatch $typo) -and ($txFull -notmatch $typo)) `
        "fast=$txFastCode $txFast full=$txFullCode $txFull"
    # ...and the agreement above is not the boring kind. Without the exclusion the same
    # fixture reddens the same lane, so the file really does carry a finding.
    Remove-Item (Join-Path $tx '_typos.toml')
    $txNone = (& pwsh -NoProfile -File $gate -Root $tx -Only base 2>&1 | Out-String)
    Check 'the excluded fixture is green because of the exclusion, not because it is clean' `
        (($LASTEXITCODE -ne 0) -and ($txNone -match '\[FAIL\] typos')) "code=$LASTEXITCODE $txNone"

    # A git hash in prose is not a misspelling. typos splits `6129afe` at the digits and
    # corrects its three-letter tail; the same run reported another such tail inside a
    # go.mod pseudo-version. Every repository puts hashes in docs and lockfiles, so the gate
    # ships the ignore and the fixture asserts BOTH halves: the hash is quiet and a real
    # typo on the same line is still red -- an ignore that swallowed the line would pass
    # the first half alone.
    $th = Join-Path $tmp 'typos-hash'
    New-Item -ItemType Directory -Path $th | Out-Null
    git -C $th init -q 2>$null
    [IO.File]::WriteAllText((Join-Path $th 'plan.md'),
        "see 6129afe and v0.0.0-20250101120000-abc123def456`n")
    $thOut = (& pwsh -NoProfile -File $gate -Root $th -Only base -Full 2>&1 | Out-String)
    Check 'a commit hash and a go.mod pseudo-version are not typos' `
        (($LASTEXITCODE -eq 0) -and ($thOut -notmatch 'plan\.md')) "code=$LASTEXITCODE $thOut"
    [IO.File]::WriteAllText((Join-Path $th 'plan.md'),
        "see 6129afe -- you will $typo it`n")
    $thOut = (& pwsh -NoProfile -File $gate -Root $th -Only base -Full 2>&1 | Out-String)
    Check 'a real typo beside a hash on the same line is still caught' `
        (($LASTEXITCODE -ne 0) -and ($thOut -match '\[FAIL\] typos') -and ($thOut -match 'plan\.md')) `
        "code=$LASTEXITCODE $thOut"
    # ...and the gate's own config must not evict the repository's. typos merges the two,
    # gitleaks' -c would have replaced the file.
    [IO.File]::WriteAllText((Join-Path $th '_typos.toml'), "[default.extend-words]`n$typo = `"$typo`"`n")
    $thOut = (& pwsh -NoProfile -File $gate -Root $th -Only base -Full 2>&1 | Out-String)
    Check "the repository's own _typos.toml still applies with the gate's config passed" `
        (($LASTEXITCODE -eq 0) -and ($thOut -notmatch 'plan\.md')) "code=$LASTEXITCODE $thOut"

    # #76: LOD (level of detail, Unity LODGroup) is a term of art, not a typo of `load`.
    # Both sides: the acronym passes, a real typo beside it is still red.
    $tlod = Join-Path $tmp 'typos-lod'
    New-Item -ItemType Directory -Path $tlod | Out-Null
    git -C $tlod init -q 2>$null
    [IO.File]::WriteAllText((Join-Path $tlod 'Mesh.cs'), "// LOD levels`nvar g = GetComponent<LODGroup>(); var lod = g.GetLODs();`n")
    $out = (& pwsh -NoProfile -File $gate -Root $tlod -Only base -Full 2>&1 | Out-String)
    Check 'LOD / LODGroup is not a typo' (($LASTEXITCODE -eq 0) -and ($out -notmatch 'Mesh\.cs')) "code=$LASTEXITCODE $out"
    [IO.File]::WriteAllText((Join-Path $tlod 'Mesh.cs'), "// LOD levels, $typo`nvar g = GetComponent<LODGroup>();`n")
    $out = (& pwsh -NoProfile -File $gate -Root $tlod -Only base -Full 2>&1 | Out-String)
    Check 'a real typo beside LODGroup is still caught' (($LASTEXITCODE -ne 0) -and ($out -match '\[FAIL\] typos') -and ($out -match 'Mesh\.cs')) "code=$LASTEXITCODE $out"

    # Encoded bytes are not prose. A vendored mail test fixture reported the same two-letter
    # fragment five times (spelled out here it would redden THIS file, exactly as the gate's
    # own config comment says), every hit a hex pair of a quoted-printable body. All three
    # shapes here, because a different pattern ignores each: the short encoded-word is far
    # below the 48-character base64 threshold and only the RFC 2047 sentinels cover it, and
    # the quoted-printable run also splits a word, so the letters glued to the escapes are
    # part of the encoded run and not a misspelling. Then the same file with a
    # real misspelling in a comment, to prove the exemption is the encoded run and not the
    # line, the string or the file.
    $tb = Join-Path $tmp 'typos-base64'
    New-Item -ItemType Directory -Path $tb | Out-Null
    git -C $tb init -q 2>$null
    $mime = @'
package email

const raw = "" +
	"Subject: =?utf-8?B?eHk5BA3eg==?=\r\n" +
	"Content-Transfer-Encoding: base64\r\n\r\n" +
	"aGVsbG8gd29ybGQgdGhpcyBpcyBhIHZlcnkgbG9uZzBiYXNlNjQgYm9keTBmb3IgdGVzdGluZw5BA3\r\n" +
	"Content-Transfer-Encoding: quoted-printable\r\n\r\n" +
	"=D0=9F=D0=BE=D0=B4=D1=81=D0=BA=D0=B0=D0=B6=D0=B8=D1=82=D0=B5\r\n" +
	"y funcion=C3=B3 de maravilla\r\n"
'@
    [IO.File]::WriteAllText((Join-Path $tb 'imap_test.go'), "$mime`n")
    $tbOut = (& pwsh -NoProfile -File $gate -Root $tb -Only base -Full 2>&1 | Out-String)
    Check 'quoted-printable, base64 and an encoded-word are not typos' `
        (($LASTEXITCODE -eq 0) -and ($tbOut -notmatch 'imap_test\.go')) "code=$LASTEXITCODE $tbOut"
    [IO.File]::WriteAllText((Join-Path $tb 'imap_test.go'), "$mime`n// you will $typo it`n")
    $tbOut = (& pwsh -NoProfile -File $gate -Root $tb -Only base -Full 2>&1 | Out-String)
    Check 'a real typo in a comment beside an encoded body is still caught' `
        (($LASTEXITCODE -ne 0) -and ($tbOut -match '\[FAIL\] typos') -and
            ($tbOut -match 'imap_test\.go')) "code=$LASTEXITCODE $tbOut"

    # A repository that never had a dictionary reports hundreds of findings on its first
    # run -- 387 measured on a game mod, 34630 chars -- and the report's 6000-char cap cut
    # that to a prefix and a byte count, never the total. typos walks the tree in parallel,
    # so the surviving prefix differed between runs on the same tree and a pre-commit hook
    # needed several of them to see one list. The phase counts and sorts for itself now.
    $tm = Join-Path $tmp 'typos-many'
    New-Item -ItemType Directory -Path $tm | Out-Null
    git -C $tm init -q 2>$null
    [IO.File]::WriteAllText((Join-Path $tm 'notes.md'),
        ((1..25 | ForEach-Object { "line $_ you will $typo it" }) -join "`n") + "`n")
    $tmOut = (& pwsh -NoProfile -File $gate -Root $tm -Only base -Full 2>&1 | Out-String)
    $tmCode = $LASTEXITCODE
    $tmHits = @($tmOut -split "`r?`n" | Where-Object { $_ -match ':\d+:\d+: ' })
    Check 'a flood of typos reports its real total and shows twenty' `
        (($tmCode -ne 0) -and ($tmHits.Count -eq 20) -and
            ($tmOut -match 'typos: 25 finding\(s\) in 1 file\(s\) -- showing first 20') -and
            ($tmOut -match 'full list: typos --format brief')) "code=$tmCode $tmOut"
    # The shown twenty must be the SAME twenty next run -- the half a byte cap could never
    # give, because the parallel walk made the surviving prefix a lottery.
    $tmAgain = @((& pwsh -NoProfile -File $gate -Root $tm -Only base -Full 2>&1 | Out-String) -split "`r?`n" |
            Where-Object { $_ -match ':\d+:\d+: ' })
    Check 'the shown findings are the same list on a second run' `
        ((($tmHits -join "`n") -eq ($tmAgain -join "`n")) -and ($tmHits.Count -eq 20)) `
        "run1=$($tmHits -join '|') run2=$($tmAgain -join '|')"
    # ...and a handful still prints in full: the summary is for a flood, not for every run.
    [IO.File]::WriteAllText((Join-Path $tm 'notes.md'), "you will $typo it`n")
    $tmFew = (& pwsh -NoProfile -File $gate -Root $tm -Only base -Full 2>&1 | Out-String)
    Check 'a couple of findings still print in full, with no summary line' `
        (($LASTEXITCODE -ne 0) -and ($tmFew -notmatch 'showing first 20') -and
            ($tmFew -match 'notes\.md')) "code=$LASTEXITCODE $tmFew"

    # #60: -Baseline filters typos to the lines changed since the rev. Both sides: an old
    # typo on an untouched line is hidden (and still red without -Baseline), a new one on a
    # changed line still fails. In a subdirectory with a space, as typos prints `.\sub dir\`.
    $tl = Join-Path $tmp 'typos-baseline'
    New-Item -ItemType Directory -Path (Join-Path $tl 'sub dir') -Force | Out-Null
    git -C $tl init -q 2>$null
    $tlFile = Join-Path $tl 'sub dir\notes.txt'
    [IO.File]::WriteAllText($tlFile, "you will $typo this`nclean line`n")
    git -C $tl add -A 2>$null
    git -C $tl -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
    [IO.File]::WriteAllText($tlFile, "you will $typo this`nclean line`nanother clean line`n")
    $out = (& pwsh -NoProfile -File $gate -Root $tl -Only base -Full 2>&1 | Out-String)
    Check 'without -Baseline a pre-existing typo still fails' (($LASTEXITCODE -ne 0) -and ($out -match '\[FAIL\] typos')) "code=$LASTEXITCODE $out"
    $out = (& pwsh -NoProfile -File $gate -Root $tl -Only base -Full -Baseline HEAD 2>&1 | Out-String)
    Check '-Baseline hides a typo on an untouched line and says so' `
        (($LASTEXITCODE -eq 0) -and ($out -notmatch $typo) -and ($out -match '\[NOTE\] typos: 1 pre-existing finding\(s\) hidden by -Baseline HEAD')) "code=$LASTEXITCODE $out"
    [IO.File]::WriteAllText($tlFile, "you will $typo this`nclean line`nwe $typo more`n")
    $out = (& pwsh -NoProfile -File $gate -Root $tl -Only base -Full -Baseline HEAD 2>&1 | Out-String)
    Check '-Baseline still fails a typo on a changed line' `
        (($LASTEXITCODE -ne 0) -and ($out -match '\[FAIL\] typos') -and ($out -match 'notes\.txt:3:') -and ($out -notmatch 'notes\.txt:1:')) "code=$LASTEXITCODE $out"
    # #80: the same baseline committed in qgate.json, so the hook's fixed command line uses it.
    $tlJson = Join-Path $tl 'qgate.json'
    $tlHead = (git -C $tl rev-parse HEAD)
    [IO.File]::WriteAllText($tlJson, "{`"baseline`": `"$tlHead`"}")
    try {
        $out = (& pwsh -NoProfile -File $gate -Root $tl -Only base -Full 2>&1 | Out-String)
        Check 'qgate.json baseline still fails a typo on a changed line' `
            (($LASTEXITCODE -ne 0) -and ($out -match 'notes\.txt:3:') -and ($out -notmatch 'notes\.txt:1:') -and
                ($out -match "\[NOTE\] baseline $tlHead from qgate\.json")) "code=$LASTEXITCODE $out"
        [IO.File]::WriteAllText($tlFile, "you will $typo this`nclean line`nanother clean line`n")
        $out = (& pwsh -NoProfile -File $gate -Root $tl -Only base -Full -Quiet 2>&1 | Out-String)
        Check 'qgate.json baseline hides a typo on an untouched line (hook run)' (($LASTEXITCODE -eq 0) -and ($out -notmatch $typo)) "code=$LASTEXITCODE $out"
        [IO.File]::WriteAllText($tlJson, '{"baseline": "no-such-rev"}')
        $out = (& pwsh -NoProfile -File $gate -Root $tl -Only base -Full -Quiet 2>&1 | Out-String)
        Check 'an unresolvable qgate.json baseline fails and names its source' `
            (($LASTEXITCODE -ne 0) -and ($out -match 'baseline revision not found: no-such-rev \(qgate\.json "baseline"\)')) "code=$LASTEXITCODE $out"
    } finally { Remove-Item $tlJson -Force }
    # A tool that fails with nothing attributable is never filtered to green.
    $tyShim = Join-Path $tmp 'typos-crash-shim'
    New-Item -ItemType Directory -Path $tyShim -Force | Out-Null
    if ($IsWindows) { [IO.File]::WriteAllText((Join-Path $tyShim 'typos.cmd'), "@echo boom: config unreadable`r`n@exit /b 2`r`n") }
    else { $p = Join-Path $tyShim 'typos'; [IO.File]::WriteAllText($p, "#!/bin/sh`necho 'boom: config unreadable'`nexit 2`n"); chmod +x $p }
    try {
        $env:PATH = "$tyShim$sep$priorPath"
        $out = (& pwsh -NoProfile -File $gate -Root $tl -Only base -Full -Baseline HEAD 2>&1 | Out-String)
        Check '-Baseline keeps a tool failure with no location red' (($LASTEXITCODE -ne 0) -and ($out -match '\[FAIL\] typos') -and ($out -match 'boom')) "code=$LASTEXITCODE $out"
    } finally { $env:PATH = $priorPath }
} else {
    Write-Output '[skip] typos not on PATH -- its fast/full scoping cannot be judged here'
}

# #60: the same -Baseline filter over the real advisory linters, each where installed.
# Old findings committed; then a new finding on a changed line for shellcheck and yamllint.
$bl = Join-Path $tmp 'lint-baseline'
New-Item -ItemType Directory -Path (Join-Path $bl 'sub dir'), (Join-Path $bl '.github\workflows') -Force | Out-Null
git -C $bl init -q 2>$null
[IO.File]::WriteAllText((Join-Path $bl 'sub dir\a.sh'), "#!/bin/sh`necho `$1`nls x`n")
[IO.File]::WriteAllText((Join-Path $bl 'sub dir\a.yml'), "---`na: 1`nb:   2`nc: 3`n")
[IO.File]::WriteAllText((Join-Path $bl '.github\workflows\ci.yml'), "on: push`njobs:`n  x:`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo `${{ github.foo }}`n")
[IO.File]::WriteAllText((Join-Path $bl '.editorconfig'), "root = true`n[*]`ntrim_trailing_whitespace = true`n")
[IO.File]::WriteAllText((Join-Path $bl 'sub dir\e.txt'), "bad `nok`n")
git -C $bl add -A 2>$null
git -C $bl -c user.email=selftest@local -c user.name=selftest commit -qm init 2>$null
$blHave = @{}
foreach ($e in 'shellcheck', 'yamllint', 'actionlint', 'editorconfig-checker') { $blHave[$e] = [bool](Get-Command $e -ErrorAction SilentlyContinue) }
$out = (& pwsh -NoProfile -File $gate -Root $bl -Only base -Full 2>&1 | Out-String)
foreach ($n in @{ shellcheck = 'shellcheck'; yamllint = 'yamllint'; actionlint = 'actionlint'; 'editorconfig-checker' = 'editorconfig' }.GetEnumerator()) {
    if ($blHave[$n.Key]) { Check "without -Baseline $($n.Value) still warns on old findings" ($out -match "\[WARN\] $($n.Value):") $out }
}
[IO.File]::WriteAllText((Join-Path $bl 'sub dir\a.sh'), "#!/bin/sh`necho `$1`nls `$y`n")
[IO.File]::WriteAllText((Join-Path $bl 'sub dir\a.yml'), "---`na: 1`nb:   2`nc:    3`n")
$out = (& pwsh -NoProfile -File $gate -Root $bl -Only base -Full -Baseline HEAD 2>&1 | Out-String)
if ($blHave['shellcheck']) {
    Check '-Baseline: shellcheck warns on the changed line only' `
        (($out -match 'a\.sh:3:\d+: ') -and ($out -notmatch 'a\.sh:2:') -and ($out -match '\[NOTE\] shellcheck: 1 pre-existing')) $out
}
if ($blHave['yamllint']) {
    Check '-Baseline: yamllint warns on the changed line only' (($out -match 'a\.yml:4:') -and ($out -notmatch 'a\.yml:3:')) $out
}
if ($blHave['actionlint']) {
    Check '-Baseline: an untouched actionlint finding is hidden with its snippet' `
        (($out -notmatch '\[WARN\] actionlint') -and ($out -notmatch 'github\.foo') -and ($out -match '\[NOTE\] actionlint: 1 pre-existing')) $out
}
if ($blHave['editorconfig-checker']) {
    Check '-Baseline: an untouched editorconfig finding is hidden' `
        (($out -notmatch '\[WARN\] editorconfig') -and ($out -match '\[NOTE\] editorconfig: 1 pre-existing')) $out
}
Check '-Baseline over advisory linters exits 0' ($LASTEXITCODE -eq 0) "code=$LASTEXITCODE $out"

# 38. secrets. Measured across nine real repositories, the phase reported 51 findings
# and every one was false -- so the two questions here are "does it still catch a real
# secret" and "has it stopped failing repositories over files git cannot commit".
#
# The planted token is assembled from two halves for the same reason the typo above is:
# written out whole it is a real finding in THIS repository, and the gate's own base
# stack goes red on its own test fixture.
if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
    $sec = Join-Path $tmp 'secrets'
    New-Item -ItemType Directory -Path (Join-Path $sec 'vendor') -Force | Out-Null
    git -C $sec init -q 2>$null
    $pat = 'ghp_' + 'S8kQ2mVx7bTnR4wLzYe1CdHu6JaGpF0iNoBq'
    # A file named by .gitignore inside a TRACKED directory. This is the case that made
    # the gate unusable: GOwebserver ignores `config.json` by name, that file holds a
    # real jwt_secret, and the run failed over it -- red, correct about the string, and
    # green-able by no action anyone could take. Filtering by directory could never see
    # it, because the directory is the repository root.
    [IO.File]::WriteAllText((Join-Path $sec '.gitignore'), "config.json`nvendor/`n")
    [IO.File]::WriteAllText((Join-Path $sec 'config.json'), "{ `"github_token`": `"$pat`" }`n")
    # ...and the directory case the phase already handled, kept asserted so the new
    # filter is not a regression of the old one.
    [IO.File]::WriteAllText((Join-Path $sec 'vendor\dump.json'), "{ `"github_token`": `"$pat`" }`n")
    # Documentation quoting a curl example, and a manifest whose ids look like keys.
    # 51 of the 51 false findings were one of these two shapes.
    [IO.File]::WriteAllText((Join-Path $sec 'API.md'),
        "curl -H `"Authorization: Bearer 0af1c39b7e5d24a8f6b013ce97d5a2b4`" https://example.test/v1`n")
    [IO.File]::WriteAllText((Join-Path $sec 'assets.json'), "{ `"key`": `"c7a9f1d24b6e4a3c8f5b7d1e9a2c4b60`" }`n")
    $out = (& pwsh -NoProfile -File $gate -Root $sec -Only base -Full 2>&1 | Out-String)
    $secCode = $LASTEXITCODE
    Check 'a secret in a gitignored FILE inside a tracked directory does not fail the gate' `
        (($secCode -eq 0) -and ($out -notmatch 'config\.json') -and ($out -notmatch 'dump\.json')) `
        "code=$secCode $out"
    Check 'a curl example and an asset manifest are not secrets' `
        (($out -notmatch 'API\.md') -and ($out -notmatch 'assets\.json')) $out
    # The green above must be the filter's doing, not a phase that stopped looking. The
    # same token, same repository, in a file nothing ignores.
    [IO.File]::WriteAllText((Join-Path $sec 'app.env'), "GITHUB_TOKEN=$pat`n")
    $out = (& pwsh -NoProfile -File $gate -Root $sec -Only base -Full 2>&1 | Out-String)
    $secCode = $LASTEXITCODE
    Check 'a real token in a tracked file still fails the gate' `
        (($secCode -ne 0) -and ($out -match '\[FAIL\] secrets') -and ($out -match 'app\.env') -and
            ($out -match 'github-pat')) "code=$secCode $out"
    # ...and it names only that file: the ignored copies of the identical token must not
    # ride along on a run that was going to be red anyway.
    Check 'the failing run still says nothing about the ignored copies' `
        (($out -notmatch 'config\.json') -and ($out -notmatch 'dump\.json')) $out
    # The fingerprint on that line is what the fix: hint tells the reader to commit to
    # .gitleaksignore, so it must not carry this machine's checkout path -- a teammate and
    # CI resolve the repository somewhere else, and an absolute fingerprint suppresses the
    # finding for exactly one person. Asserted as "no drive letter, nothing of $sec in it",
    # and then as the thing the hint actually promises: that line, committed, takes the
    # same run to green.
    $fp = (($out -split "`n" | Select-String 'app\.env:.*github-pat -- ' | Select-Object -First 1) -split ' -- ')[-1].Trim()
    Check 'the printed fingerprint is repo-relative, not a path on this machine' `
        ($fp -and ($fp -notmatch '^[A-Za-z]:') -and ($fp -notmatch [regex]::Escape($sec)) -and
            ($fp -like 'app.env:github-pat:*')) "fingerprint=$fp"
    [IO.File]::WriteAllText((Join-Path $sec '.gitleaksignore'), "$fp`n")
    $out = (& pwsh -NoProfile -File $gate -Root $sec -Only base -Full 2>&1 | Out-String)
    Check 'that fingerprint in .gitleaksignore suppresses the finding' `
        (($LASTEXITCODE -eq 0) -and ($out -notmatch 'app\.env')) "code=$LASTEXITCODE $out"
} else {
    Write-Output '[skip] gitleaks not on PATH -- the secrets filter cannot be judged here'
}

}

if (Want 'web') {
# 39. The web stack linted, type-checked, built and audited -- and never ran the
# test script the repository itself declares, so a project whose suite was red went
# through the gate green. The two halves: a declared `test` that exits non-zero must
# be the thing that fails the full run, and a project that declares none must be
# exactly as silent as it was before.
if (Get-Command npm -ErrorAction SilentlyContinue) {
    $wt = Join-Path $tmp 'webtest'
    Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') $wt -Recurse
    New-Item -ItemType Directory -Path (Join-Path $wt 'node_modules\.bin') -Force | Out-Null
    # No eslint/stylelint config, no tsconfig: `build` and `test` are the only phases
    # this fixture has, which is what makes the failure attributable to one of them.
    [IO.File]::WriteAllText((Join-Path $wt 'package.json'),
        '{"name":"webtest","private":true,"type":"module","scripts":{"build":"node -e \"process.exit(0)\"","test":"node -e \"process.exit(1)\""}}')
    $out = (& pwsh -NoProfile -File $gate -Root $wt -Only 'web' -Full 2>&1 | Out-String)
    $wtCode = $LASTEXITCODE
    Check 'a failing npm test script fails the full gate' `
        (($wtCode -ne 0) -and ($out -match '(?m)^\[FAIL\] test\b')) "code=$wtCode $out"
    # ...and it is the test step that is named. A red `build` line here would be the
    # same exit code standing on a different reason.
    Check 'the failure names the test step, not the build' `
        (($out -notmatch '(?m)^\[FAIL\] build') -and ($out -match '(?m)^\[PASS\] build')) $out
    # The fast lane runs on every agent turn and never promised the expensive phases.
    # This fixture's test script is red, so a fast run that touched it could not stay
    # quiet about it.
    $out = (& pwsh -NoProfile -File $gate -Root $wt -Only 'web' -Fast 2>&1 | Out-String)
    Check 'the fast lane does not run the test script' ($out -notmatch '(?m)^\[(PASS|FAIL)\] test\b') $out
    # No `test` declared: nothing to ask, nothing said, same verdict as before.
    [IO.File]::WriteAllText((Join-Path $wt 'package.json'),
        '{"name":"webtest","private":true,"type":"module","scripts":{"build":"node -e \"process.exit(0)\""}}')
    $out = (& pwsh -NoProfile -File $gate -Root $wt -Only 'web' -Full 2>&1 | Out-String)
    $wtCode = $LASTEXITCODE
    Check 'a web project that declares no test script is unaffected' `
        (($wtCode -eq 0) -and ($out -notmatch '(?m)^\[(PASS|FAIL)\] test\b')) "code=$wtCode $out"
} else {
    Write-Output '[skip] npm not on PATH -- the web test phase cannot be judged here'
}

}

if (Want 'bootstrap') {
# #79: re-running bootstrap updates the install `qgate` already resolves to instead of
# cloning a new copy; a qgate on PATH that is not a clone of this repo is not adopted.
# No network: url.insteadOf redirects the origin URL to a local bare repo, and
# GITHUB_PATH keeps the child off the registry PATH.
$bs = Join-Path $tmp 'bootstrap79'
$bsSrc = Join-Path $bs 'src'
New-Item -ItemType Directory -Force (Join-Path $bsSrc 'bin') | Out-Null
Set-Content (Join-Path $bsSrc 'bin\qgate.ps1') 'exit 0'
git -C $bsSrc init -q -b main 2>&1 | Out-Null
git -C $bsSrc add -A 2>&1 | Out-Null
git -C $bsSrc -c user.name=t -c user.email=t@t commit -qm init 2>&1 | Out-Null
git clone -q --bare $bsSrc (Join-Path $bs 'bare.git') 2>&1 | Out-Null
$bsOrigin = 'https://github.com/UberMorgott/quality-gate.git'
$bsUrl = 'file:///' + ((Join-Path $bs 'bare.git') -replace '\\', '/')
# Every other qgate is taken off the child's PATH: when a fixture clone failed (a TEMP path
# past MAX_PATH, measured), bootstrap adopted the developer's real install instead and
# fetched this fixture's bare repo over its origin/main.
function Invoke-Bootstrap79([string]$Inst, [string]$Name) {
    $qh = Join-Path $bs "qh-$Name"
    $cmd = "`$env:QUALITY_GATE_HOME=`$null; `$env:QGATE_HOME='$qh'; `$env:GITHUB_PATH='$bs\gp-$Name.txt'; " +
        "`$env:GIT_CONFIG_COUNT='1'; `$env:GIT_CONFIG_KEY_0='url.$bsUrl.insteadOf'; `$env:GIT_CONFIG_VALUE_0='$bsOrigin'; " +
        "`$env:Path='$Inst\bin;' + ((`$env:Path -split ';' | Where-Object { `$_ -and -not (Test-Path (Join-Path `$_ 'qgate.ps1')) }) -join ';'); " +
        "& '$(Join-Path $PSScriptRoot 'bootstrap.ps1')'"
    [pscustomobject]@{ Out = (& pwsh -NoProfile -Command $cmd 2>&1 | Out-String); Cloned = (Test-Path (Join-Path $qh 'quality-gate')) }
}
$bsInst = Join-Path $bs 'inst'
git clone -q $bsUrl $bsInst 2>&1 | Out-Null
git -C $bsInst remote set-url origin $bsOrigin 2>&1 | Out-Null
$r = Invoke-Bootstrap79 $bsInst 'own'
Check 'bootstrap updates the qgate install already on PATH' ((-not $r.Cloned) -and ($r.Out -match [regex]::Escape("installed $bsInst"))) $r.Out
$bsOther = Join-Path $bs 'other'
git clone -q $bsUrl $bsOther 2>&1 | Out-Null
git -C $bsOther remote set-url origin 'https://example.invalid/other.git' 2>&1 | Out-Null
$r = Invoke-Bootstrap79 $bsOther 'foreign'
Check 'bootstrap does not adopt a qgate on PATH from another repository' $r.Cloned $r.Out

}
Remove-Item $tmp -Recurse -Force
if ($script:Total -eq 0) { Write-Output "`nno checks ran"; exit 1 }
if ($script:Fails) { Write-Output "`n$($script:Fails) of $($script:Total) check(s) failed"; exit 1 }
Write-Output "`nall checks passed ($($script:Total)/$($script:Total))"
exit 0
