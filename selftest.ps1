# Self-test: proves the gate FAILS on a real violation and PASSES once it is
# fixed. A gate nobody has seen fail is not known to work.
#
#   pwsh -NoProfile -File selftest.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gate\detect.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) 'quality-gate-selftest'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp | Out-Null

$script:Fails = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Output "[ok]   $Name" }
    else { Write-Output "[FAIL] $Name $Detail"; $script:Fails++ }
}
function Set-GoFile([string]$Path, [string]$Text) {
    # LF only: gofmt reports a CRLF file as unformatted, which would fail the
    # wrong phase and hide the violation we are testing for.
    [IO.File]::WriteAllText($Path, (($Text -replace "`r`n", "`n").TrimEnd() + "`n"))
}
function Invoke-Gate([string]$Root) {
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'gate\check.ps1') -Root $Root -All 2>&1 | Out-String)
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

# 1. Detection by file presence.
$stacks = @(Get-Stacks (Join-Path $PSScriptRoot 'testdata'))
Check 'detects go stack'   ([bool]($stacks | Where-Object { $_.Stack -eq 'go' -and $_.Implemented }))
Check 'detects web stack'  ([bool]($stacks | Where-Object { $_.Stack -eq 'web' -and $_.Implemented }))
Check 'rust marked not implemented' ([bool]($stacks | Where-Object { $_.Stack -eq 'rust' -and -not $_.Implemented }))
Check 'no phantom python stack' (-not ($stacks | Where-Object { $_.Stack -eq 'python' }))

# 2. Clean Go fixture, no linter config -> passes, warns exactly once.
$go = Join-Path $tmp 'go'
Copy-Item (Join-Path $PSScriptRoot 'testdata\go-fixture') $go -Recurse
$r = Invoke-Gate $go
Check 'clean go fixture passes without config' ($r.Code -eq 0) $r.Out
Check 'missing .golangci.yml warned once' (([regex]::Matches($r.Out, 'no \.golangci\.yml')).Count -eq 1) $r.Out

# 3. Same fixture with the template config -> still green, no warning.
Copy-Item (Join-Path $PSScriptRoot 'templates\.golangci.yml') $go
$r = Invoke-Gate $go
Check 'template .golangci.yml passes' ($r.Code -eq 0) $r.Out
Check 'no warning once config present' ($r.Out -notmatch 'WARN') $r.Out

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

# 8. Fail closed: an unusable root is a failure, never "nothing to check".
$r = Invoke-Gate (Join-Path $tmp 'does-not-exist')
Check 'unusable root fails closed' ($r.Code -ne 0) $r.Out

# 9. A present-but-unverifiable stack must FAIL, never pass silently.
$web = Join-Path $tmp 'web'
Copy-Item (Join-Path $PSScriptRoot 'testdata\web-fixture') $web -Recurse
$r = Invoke-Gate $web
Check 'web without node_modules fails loudly' (($r.Code -ne 0) -and ($r.Out -match 'node_modules missing')) $r.Out

# 10. The agent contract: `qgate stop-hook` must reach Claude Code as exit code 2
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
    $hookOut = '{"session_id":"selftest"}' |
        & cmd /c "`"$(Join-Path $PSScriptRoot 'bin\qgate.cmd')`" stop-hook" 2>$stderrFile
    $hookCode = $LASTEXITCODE
    $env:CLAUDE_PROJECT_DIR = $null
} finally { Pop-Location }
$hookErr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { '' }
Check 'stop-hook blocks the turn with exit 2' ($hookCode -eq 2) "code=$hookCode"
Check 'stop-hook puts the reason on stderr' ($hookErr -match 'Quality gate failed') $hookErr
Check 'stop-hook keeps stdout clean' ([string]::IsNullOrWhiteSpace(($hookOut | Out-String))) ($hookOut | Out-String)

Remove-Item $tmp -Recurse -Force
if ($script:Fails) { Write-Output "`n$($script:Fails) check(s) failed"; exit 1 }
Write-Output "`nall checks passed"
