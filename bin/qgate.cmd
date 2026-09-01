@echo off
rem Shim so `qgate` works from cmd.exe, git hooks and Claude Code hooks.
rem `exit /b` propagates the child's exit code unchanged -- the Stop hook needs
rem exit 2 to reach Claude Code intact.
rem Nothing may be added here: no pipes, no 2>&1, no logging -- stdin must reach
rem the Stop hook and stderr must reach Claude Code unmodified.
pwsh.exe -NoLogo -NoProfile -NonInteractive -File "%~dp0qgate.ps1" %*
exit /b %ERRORLEVEL%
