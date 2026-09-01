# One-line installer. Clones (or updates) the quality gate for the current user
# and puts `qgate` on PATH. Safe to re-run.
#
#   irm https://raw.githubusercontent.com/UberMorgott/quality-gate/main/bootstrap.ps1 | iex
#
# Override the install directory by setting $env:QUALITY_GATE_HOME first.
$ErrorActionPreference = 'Stop'

$repo = 'https://github.com/UberMorgott/quality-gate.git'
$dir = if ($env:QUALITY_GATE_HOME) { $env:QUALITY_GATE_HOME } else { Join-Path $env:LOCALAPPDATA 'quality-gate' }

if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7+ required: winget install Microsoft.PowerShell' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git required and not on PATH' }

if (Test-Path (Join-Path $dir '.git')) {
    git -C $dir pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull failed in $dir -- fix or delete that directory and re-run" }
} else {
    git clone --depth 1 $repo $dir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed into $dir" }
}

$bin = Join-Path $dir 'bin'
$env:Path = "$env:Path;$bin"

if ($env:GITHUB_PATH) {
    # A registry PATH edit does not survive into the next Actions step.
    Add-Content -Path $env:GITHUB_PATH -Value $bin
    Write-Output "PATH      += $bin  (GITHUB_PATH)"
} else {
    # Read the raw user PATH from the registry: SetEnvironmentVariable would otherwise
    # write back an expanded copy and freeze whatever %VARS% other installers put there.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    $path = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    if (($path -split ';') -notcontains $bin) {
        # An empty segment in PATH means "the current directory" -- never leave a
        # leading or doubled ';' behind. And keep the value's existing kind: turning
        # a REG_SZ into REG_EXPAND_SZ would start expanding literal % in other entries.
        $kind = if ($path) { $key.GetValueKind('Path') } else { 'ExpandString' }
        $merged = (@($path -split ';') + $bin | Where-Object { $_ }) -join ';'
        $key.SetValue('Path', $merged, $kind)
        Write-Output "PATH      += $bin"
    }
    $key.Dispose()
}

Write-Output "installed $dir  $(git -C $dir rev-parse --short HEAD)"
Write-Output 'Restart your terminals and any running agent -- they hold the old PATH.'
Write-Output 'next:     cd <your repo>; qgate wire'
