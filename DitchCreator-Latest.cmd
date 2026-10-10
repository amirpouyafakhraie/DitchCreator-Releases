@echo off
setlocal
set "LAUNCHER=%~dpn0.ps1"
if not exist "%LAUNCHER%" set "LAUNCHER=%~dp0DitchCreator-Latest.ps1"
if not exist "%LAUNCHER%" (
  echo Missing PowerShell launcher. Keep the CMD and PS1 files together.
  exit /b 2
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" %*
exit /b %errorlevel%

