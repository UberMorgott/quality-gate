# Stack detection by file presence. Dot-sourced by check.ps1 and install.ps1.
#
# A stack with no marker file DOES NOT EXIST: it costs nothing and is never
# mentioned. A stack whose marker is present but whose linter config is missing
# is reported once, clearly, and the run continues.

# Every stack this gate knows about and the file that proves it exists.
# Used for provenance output: `check.ps1 -Why` names the marker behind every
# phase that ran and every stack that does not exist here.
$script:KnownMarkers = [ordered]@{
    go     = 'go.mod'
    web    = 'package.json + vite/next/webpack/rollup.config.*'
    godot  = 'project.godot'
    proto  = 'buf.yaml'
    python = 'pyproject.toml or requirements.txt'
    rust   = 'Cargo.toml'
}

# Directories that never hold a project we own.
$script:SkipDirs = @('node_modules', '.git', 'vendor', 'dist', 'build', '.cache', '.venv', 'target', 'bin', 'obj')

function Get-RepoRoot([string]$StartDir) {
    $top = (& git -C $StartDir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $top) { return (Resolve-Path ($top -replace '/', '\')).Path }
    return (Resolve-Path $StartDir).Path
}

function Find-Marker([string]$Root, [string[]]$Names, [int]$Depth = 3) {
    Get-ChildItem -Path $Root -Recurse -Depth $Depth -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $Names -contains $_.Name -and
            ($_.FullName.Substring($Root.Length) -split '[\\/]' | Where-Object { $script:SkipDirs -contains $_ }).Count -eq 0
        }
}

# Stable short key for a path: names per-repo temp files and build directories so
# two repos (or two agents in different worktrees) never share one.
function Get-PathKey([string]$Text) {
    [BitConverter]::ToString(
        [Security.Cryptography.MD5]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant()))).Replace('-', '')
}

# The Godot editor binary is almost never on PATH on Windows (no installer, no
# stable name), so GODOT_BIN is the primary answer and PATH the fallback.
function Get-GodotBin {
    if ($env:GODOT_BIN -and (Test-Path $env:GODOT_BIN)) { return $env:GODOT_BIN }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-AnyFile([string]$Dir, [string[]]$Patterns) {
    foreach ($p in $Patterns) {
        if (Get-ChildItem -Path $Dir -Filter $p -File -Force -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# Returns one object per detected stack:
#   Stack       go | web | godot | proto | python | rust
#   Dir         absolute directory holding the marker
#   Rel         path relative to the repo root, forward slashes, '' for the root
#   Marker      the file whose presence created this phase (provenance)
#   Implemented $true only for stacks this gate actually checks
#   Warn        one-line message about missing tooling/config, or ''
function Get-Stacks([string]$Root) {
    $stacks = @()
    $rel = {
        param($d)
        $r = $d.Substring($Root.Length).Trim('\').Replace('\', '/')
        $r
    }

    foreach ($m in Find-Marker $Root @('go.mod')) {
        $dir = $m.DirectoryName
        $warn = ''
        if (-not (Test-Path (Join-Path $dir '.golangci.yml')) -and -not (Test-Path (Join-Path $dir '.golangci.yaml'))) {
            $warn = 'no .golangci.yml -- running golangci-lint on its defaults; copy templates/.golangci.yml'
        }
        $stacks += [pscustomobject]@{ Stack = 'go'; Dir = $dir; Rel = (& $rel $dir); Marker = 'go.mod'; Implemented = $true; Warn = $warn }
    }

    foreach ($m in Find-Marker $Root @('package.json')) {
        $dir = $m.DirectoryName
        $bundler = @('vite.config.*', 'next.config.*', 'webpack.config.*', 'rollup.config.*') |
            Where-Object { Test-AnyFile $dir @($_) } | Select-Object -First 1
        if (-not $bundler) { continue }
        $warn = ''
        if (-not (Test-Path (Join-Path $dir 'node_modules'))) {
            $warn = 'node_modules missing -- run npm ci; the gate cannot verify this stack until then'
        }
        $stacks += [pscustomobject]@{ Stack = 'web'; Dir = $dir; Rel = (& $rel $dir); Marker = "package.json + $bundler"; Implemented = $true; Warn = $warn }
    }

    foreach ($m in Find-Marker $Root @('Cargo.toml')) {
        $dir = $m.DirectoryName
        # A workspace member has no [package] of its own to build; the workspace
        # root already covers it.
        if ((Get-Content $m.FullName -Raw) -notmatch '(?m)^\s*\[package\]') { continue }
        $warn = ''
        if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
            $warn = 'cargo not on PATH -- the gate cannot verify this stack until it is'
        }
        $stacks += [pscustomobject]@{ Stack = 'rust'; Dir = $dir; Rel = (& $rel $dir); Marker = 'Cargo.toml'; Implemented = $true; Warn = $warn }
    }

    foreach ($m in Find-Marker $Root @('buf.yaml')) {
        $dir = $m.DirectoryName
        $warn = ''
        if (-not (Get-Command buf -ErrorAction SilentlyContinue)) {
            $warn = 'buf not on PATH -- the gate cannot verify this stack until it is'
        }
        $stacks += [pscustomobject]@{ Stack = 'proto'; Dir = $dir; Rel = (& $rel $dir); Marker = 'buf.yaml'; Implemented = $true; Warn = $warn }
    }

    foreach ($m in Find-Marker $Root @('project.godot')) {
        $dir = $m.DirectoryName
        $warn = ''
        if (-not (Get-GodotBin)) {
            $warn = 'no Godot binary -- set GODOT_BIN; the gate cannot verify this stack until then'
        }
        $stacks += [pscustomobject]@{ Stack = 'godot'; Dir = $dir; Rel = (& $rel $dir); Marker = 'project.godot'; Implemented = $true; Warn = $warn }
    }

    # Declared, detected, NOT checked. Reported so nobody mistakes silence for a
    # passing stack. Implement one only after it has been run for real.
    $todo = @{ 'pyproject.toml' = 'python'; 'requirements.txt' = 'python' }
    foreach ($m in Find-Marker $Root ($todo.Keys)) {
        $dir = $m.DirectoryName
        $name = $todo[$m.Name]
        if ($stacks | Where-Object { $_.Stack -eq $name -and $_.Dir -eq $dir }) { continue }
        $stacks += [pscustomobject]@{ Stack = $name; Dir = $dir; Rel = (& $rel $dir); Marker = $m.Name; Implemented = $false; Warn = 'not implemented -- nothing is checked here' }
    }

    $stacks
}
