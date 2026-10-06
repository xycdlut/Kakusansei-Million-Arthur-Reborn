@echo off
REM Double-clickable launcher for install-all.ps1.
REM
REM Why this exists: double-clicking a .ps1 usually opens it in an editor, and
REM even when it does run it happens under the machine's execution policy - so
REM on a locked-down box the window flashes and disappears before any message
REM can be read. This wrapper pins the policy for this one call, forwards every
REM argument, and always keeps the window open.
REM
REM ASCII-only so any Windows code page reads it safely.
setlocal

set "SCRIPT=%~dp0install-all.ps1"
if not exist "%SCRIPT%" (
    echo install-all.ps1 not found next to this launcher:
    echo   %SCRIPT%
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo install-all.ps1 finished. exit=%RC%
) else (
    echo install-all.ps1 FAILED. exit=%RC%
)
echo.
pause
exit /b %RC%
