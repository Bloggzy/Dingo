@echo off
setlocal
REM The GUI needs no console window, so tell Dingo to hide this one. Only when
REM no arguments were given: a command line run must keep its output on screen.
if "%~1"=="" set "DINGO_HIDE_CONSOLE=1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Dingo.ps1" %*
set "DINGO_EXIT=%ERRORLEVEL%"
if not "%DINGO_EXIT%"=="0" pause
exit /b %DINGO_EXIT%
