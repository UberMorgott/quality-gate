# `qgate tools [name ...]`: download the gate's opt-in linters into <install>\tools\bin
# (gitignored), pinned and SHA-256 checked. Nothing goes on PATH or into a package
# manager: the gate resolves this directory before PATH (Get-ToolPath in check.ps1).
# The only network the gate does for these tools, and only when asked. No name = all.
# shortcut: Windows x64 assets only, like the rest of the gate; add rows per OS/arch if it ever runs elsewhere.
param([string[]]$Name)
$ErrorActionPreference = 'Stop'

$pins = [ordered]@{
    # https://github.com/betterleaks/betterleaks/releases/tag/v1.10.1 (checksums.txt)
    betterleaks = @{ Url = 'https://github.com/betterleaks/betterleaks/releases/download/v1.10.1/betterleaks_1.10.1_windows_x64.zip'
        Sha256 = '53d4b37635a999992fb8e1d79f8215279315cbb3b4139314289b69407e79143d'; Exe = 'betterleaks.exe' }
    # https://github.com/oxc-project/oxc/releases/tag/oxlint_v1.93.0 (GitHub asset digest)
    oxlint = @{ Url = 'https://github.com/oxc-project/oxc/releases/download/oxlint_v1.93.0/oxlint-x86_64-pc-windows-msvc.zip'
        Sha256 = '075ce1f3baae778da2a37a0bae8c31040f31f9ca3e1b89c60775f82f09661724'; Exe = 'oxlint-x86_64-pc-windows-msvc.exe' }
}

$Name = @($Name -split ',' | ForEach-Object Trim | Where-Object { $_ })
if (-not $Name) { $Name = @($pins.Keys) }
$bad = @($Name | Where-Object { -not $pins.Contains($_) })
if ($bad) { Write-Output "qgate tools: unknown tool(s) $($bad -join ', '); known: $($pins.Keys -join ', ')"; exit 1 }

$bin = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
foreach ($n in $Name) {
    $p = $pins[$n]
    $work = Join-Path ([IO.Path]::GetTempPath()) "qgate-tools-$n-$PID"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $zip = Join-Path $work 'a.zip'
        Invoke-WebRequest -Uri $p.Url -OutFile $zip -UseBasicParsing
        $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($got -ne $p.Sha256) { Write-Output "qgate tools: $n checksum mismatch (got $got, pinned $($p.Sha256)) -- not installed"; exit 1 }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x') -Force
        Copy-Item -LiteralPath (Join-Path $work "x\$($p.Exe)") -Destination (Join-Path $bin "$n.exe") -Force
        Write-Output "installed $n -> $(Join-Path $bin "$n.exe")"
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
