@echo off
rem Opens the PC Maintenance window. Keep this file next to Invoke-PCMaintenance.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Invoke-PCMaintenance.ps1"
if errorlevel 1 pause
