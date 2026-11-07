@echo off
rem diskinfer.cmd - Windows shim for the diskinfer launcher (diskinfer.ps1).
rem Keeps the command name identical to the Termux/Termux-style entry point and
rem bypasses the default PowerShell execution policy for this one script only.
rem All arguments are forwarded untouched; quoted arguments keep their quotes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diskinfer.ps1" %*
exit /b %ERRORLEVEL%
