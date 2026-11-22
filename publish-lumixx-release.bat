@echo off
setlocal
chcp 65001 >nul
title LumixX Release Publisher

echo.
echo ==========================================
echo          LUMIXX RELEASE PUBLISHER
echo ==========================================
echo.

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: Windows PowerShell was not found.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-lumixx-release.ps1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo Publishing failed. See the error above.
) else (
    echo Publishing completed.
)
pause
exit /b %RC%
