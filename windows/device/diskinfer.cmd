@echo off
rem diskinfer.cmd - Windows shim for the diskinfer launcher (diskinfer.ps1).
rem Keeps the command name identical to the Termux entry point and bypasses the
rem default PowerShell execution policy for this one script only. All arguments
rem are forwarded untouched; quoted arguments keep their quotes.
rem
rem messages: en / zh-Hans / zh-Hant (contract v5 §1.3). Everything user-visible
rem normally comes from diskinfer.ps1; this shim only speaks when PowerShell
rem itself is missing. Language for that path:
rem   DISKINFER_LANG > LC_ALL > LANG > Windows install language (registry) > en
rem The Chinese messages are stored as UTF-8; the console is switched to UTF-8
rem (chcp 65001) for the duration of the error output and restored afterwards.
setlocal

where powershell >nul 2>nul
if not errorlevel 1 goto run

set "LANGTAG=%DISKINFER_LANG%"
if not defined LANGTAG set "LANGTAG=%LC_ALL%"
if not defined LANGTAG set "LANGTAG=%LANG%"
if not defined LANGTAG call :detect_lang

rem normalize the tag: *Hant/TW/HK/MO -> zh-Hant, zh* -> zh-Hans, else en
if /i "%LANGTAG%"=="auto" set "LANGTAG="
if not defined LANGTAG call :detect_lang
echo %LANGTAG%| findstr /i /c:"hant" /c:"tw" /c:"hk" /c:"mo" >nul
if not errorlevel 1 set "LANGTAG=zh-Hant"
if /i "%LANGTAG%"=="zh-Hant" goto err_lang_ready
echo %LANGTAG%| findstr /i /r "^zh" >nul
if not errorlevel 1 set "LANGTAG=zh-Hans"
:err_lang_ready
if /i "%LANGTAG%"=="zh-Hans" goto err_hans
if /i "%LANGTAG%"=="zh-Hant" goto err_hant

:err_en
for /f "tokens=2 delims=:" %%A in ('chcp') do set "OLDCP=%%A"
set "OLDCP=%OLDCP: =%"
chcp 65001 >nul
echo diskinfer: Windows PowerShell not found.
echo Install Windows PowerShell 5.1+ (or add powershell.exe to PATH), then run diskinfer again.
if defined OLDCP chcp %OLDCP% >nul
exit /b 1

:err_hans
for /f "tokens=2 delims=:" %%A in ('chcp') do set "OLDCP=%%A"
set "OLDCP=%OLDCP: =%"
chcp 65001 >nul
echo diskinfer: 没有找到 Windows PowerShell。
echo 请安装 Windows PowerShell 5.1+（或把 powershell.exe 加进 PATH），然后重新运行 diskinfer。
if defined OLDCP chcp %OLDCP% >nul
exit /b 1

:err_hant
for /f "tokens=2 delims=:" %%A in ('chcp') do set "OLDCP=%%A"
set "OLDCP=%OLDCP: =%"
chcp 65001 >nul
echo diskinfer: 沒有找到 Windows PowerShell。
echo 請安裝 Windows PowerShell 5.1+（或把 powershell.exe 加進 PATH），然後重新執行 diskinfer。
if defined OLDCP chcp %OLDCP% >nul
exit /b 1

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diskinfer.ps1" %*
exit /b %ERRORLEVEL%

:detect_lang
rem Windows install language LCID: 0804/1004 = Chinese(simplified), 0404/0c04/1404 = traditional
set "LCID="
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Nls\Language" /v InstallLanguage 2^>nul') do set "LCID=%%A"
set "LANGTAG=en"
if /i "%LCID%"=="0804" set "LANGTAG=zh-Hans"
if /i "%LCID%"=="1004" set "LANGTAG=zh-Hans"
if /i "%LCID%"=="0404" set "LANGTAG=zh-Hant"
if /i "%LCID%"=="0c04" set "LANGTAG=zh-Hant"
if /i "%LCID%"=="1404" set "LANGTAG=zh-Hant"
exit /b 0
