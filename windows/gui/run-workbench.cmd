@echo off
rem diskinfer Windows test workbench launcher (PySide6 GUI).
rem Same command name scheme as device\diskinfer.cmd: all arguments are forwarded.
setlocal
cd /d "%~dp0.."
set "PY=python"
where python >nul 2>nul
if errorlevel 1 set "PY=py -3"
%PY% "%~dp0workbench.py" %*
exit /b %errorlevel%
