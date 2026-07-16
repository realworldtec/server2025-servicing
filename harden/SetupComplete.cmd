@echo off
REM ============================================================================
REM  SetupComplete.cmd
REM
REM  Windows Setup runs %WINDIR%\Setup\Scripts\SetupComplete.cmd AUTOMATICALLY
REM  after installation finishes and BEFORE the first user logon, in the SYSTEM
REM  context. That is the ideal moment to apply machine-wide + Default-user
REM  privacy hardening, so every profile created afterward inherits it.
REM
REM  It expects Invoke-PrivacyHardening.ps1 to sit in the SAME folder (this file's
REM  directory = %~dp0). Both land in C:\Windows\Setup\Scripts when placed on the
REM  install media under:  sources\$OEM$\$$\Setup\Scripts\
REM  (see docs/PRIVACY-HARDENING.md).
REM
REM  Logs to C:\ProgramData\PrivacyHardening\ . Never blocks OOBE: a failure here
REM  is logged, not fatal (the /c exits regardless).
REM ============================================================================

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0Invoke-PrivacyHardening.ps1"

if not exist "%SCRIPT%" (
    echo [SetupComplete] %SCRIPT% not found - skipping hardening.>> "%SystemDrive%\ProgramData\PrivacyHardening_missing.txt"
    exit /b 0
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

REM Always succeed so a hardening hiccup can never wedge first boot.
exit /b 0
