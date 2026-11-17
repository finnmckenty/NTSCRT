@echo off
rem Starts the MCP server built into NTSCRT for Windows (`ntscrt.exe mcp`).
rem The extension carries only this launcher: the server is the NTSCRT folder
rem the user unzipped, which ntscrt.exe records in HKCU\Software\NTSCRT when
rem it opens (Path, Version).
setlocal EnableDelayedExpansion
set "exe="
set "ver="
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\NTSCRT" /v Path 2^>nul ^| find "REG_SZ"') do set "exe=%%b"
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\NTSCRT" /v Version 2^>nul ^| find "REG_SZ"') do set "ver=%%b"
if defined exe if exist "!exe!" goto found
set "exe="
rem Not opened yet: the usual places to unzip it. Only a package with
rem ntscrt-cli.exe beside ntscrt.exe has the server.
set "old="
for %%p in ("%USERPROFILE%\Documents\NTSCRT" "%USERPROFILE%\Desktop\NTSCRT" "%USERPROFILE%\Downloads\NTSCRT" "%USERPROFILE%\NTSCRT" "%LOCALAPPDATA%\Programs\NTSCRT" "%ProgramFiles%\NTSCRT" "C:\NTSCRT") do (
  if not defined exe if exist "%%~p\ntscrt.exe" (
    if exist "%%~p\ntscrt-cli.exe" (set "exe=%%~p\ntscrt.exe") else (set "old=%%~p")
  )
)
if defined exe goto run
if defined old goto tooold
echo NTSCRT isn't installed. Download it from https://github.com/finnmckenty/NTSCRT/releases/latest, unzip the NTSCRT folder somewhere it can stay, open ntscrt.exe once, then restart Claude. 1>&2
exit /b 1
:found
rem Version is major.minor.patch, or "dev" for a build of the repo.
for /f "tokens=1,2 delims=.-" %%a in ("!ver!") do (set "major=%%a" & set "minor=%%b")
set /a "num=major*1000+minor" 2>nul
if "!ver!"=="dev" goto run
if !num! lss 26 (set "old=!exe!" & goto tooold)
:run
"!exe!" mcp
exit /b !errorlevel!
:tooold
echo NTSCRT at !old! is too old for Claude: update it to the latest version (Help ^> Check for Updates...), open it once, then restart Claude. 1>&2
exit /b 1
