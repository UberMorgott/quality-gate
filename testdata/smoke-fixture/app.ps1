# Smoke fixture for selftest: a tiny WinForms app driven by gate/smoke.ps1.
#   pwsh -File app.ps1 <mode> <dataDir> [color]
# pass    logs "Starting menu", then "Spawned in world", runs until closed
# error   pass + one exception block
# repeat  pass + the same exception on every tick
# hang    never logs a ready marker
# crash   exits 3 before any ready marker
# The window sits off-screen: PrintWindow still captures it, and the selftest does not
# cover the developer's desktop. It keeps its taskbar button: a form without one is an
# owned window, and Process.MainWindowHandle skips owned windows.
param([string]$Mode, [string]$DataDir, [string]$Color = 'SeaGreen')
$script:log = Join-Path $DataDir 'app.log'
function Write-Log([string]$t) { try { [IO.File]::AppendAllText($script:log, "$t`n") } catch { } }
# The app's "user data": proves it landed in the dir the gate handed out.
[IO.File]::WriteAllText((Join-Path $DataDir 'save.dat'), "env=$env:QGATE_DATA_DIR")
Write-Log 'boot'
if ($Mode -eq 'crash') { exit 3 }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$f = [Windows.Forms.Form]::new()
$f.StartPosition = 'Manual'
$f.Location = [Drawing.Point]::new(-3000, -3000)
$f.Size = [Drawing.Size]::new(160, 100)
$f.BackColor = [Drawing.Color]::FromName($Color)
$f.Text = 'qgate smoke fixture'
$script:n = 0
$t = [Windows.Forms.Timer]::new()
$t.Interval = 200
$t.add_Tick({
        $script:n++
        if ($Mode -eq 'hang') { return }
        if ($script:n -eq 1) { Write-Log 'Starting menu' }
        if ($script:n -eq 3) { Write-Log 'Spawned in world' }
        if ($Mode -eq 'error' -and $script:n -eq 4) { Write-Log "NullReferenceException: boom`n  at Fixture.Hud.Awake ()" }
        if ($Mode -eq 'repeat') { Write-Log "NullReferenceException: tick $($script:n)`n  at Fixture.Chat.HasFocus ()" }
    })
$f.add_Shown({ $t.Start() })
[Windows.Forms.Application]::Run($f)
Write-Log 'closed'
