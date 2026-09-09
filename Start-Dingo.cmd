@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Dingo.ps1" %*
set "DINGO_EXIT=%ERRORLEVEL%"
if not "%DINGO_EXIT%"=="0" pause
exit /b %DINGO_EXIT%
