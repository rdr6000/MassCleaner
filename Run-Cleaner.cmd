@echo off
title Mass Workspace Cleaner
color 0a

echo Starting Workspace Cleaner...
echo =====================================================

:: Check if PowerShell 7+ (pwsh) is installed, fallback to older Windows PowerShell
WHERE pwsh >nul 2>nul
IF %ERRORLEVEL% EQU 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0WorkspaceCleaner.ps1"
) ELSE (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WorkspaceCleaner.ps1"
)

echo.
pause
