@echo off
rem ---------------------------------------------------------------------------
rem  Start-ClaudePane.cmd  <name> [1-4] [-noclaude]
rem
rem  Startup script for one Claude window: name the console, print a coloured
rem  banner so the window is identifiable at a glance, then start Claude.
rem
rem  Lives in its own file rather than inline in the wt.exe command line because
rem  wt.exe splits its command line on ';' even inside a quoted argument, which
rem  shreds any inline multi-statement command.
rem
rem  The colour table lives here for the same reason: ANSI colour codes are
rem  semicolon-separated, so passing one through wt.exe would split the command.
rem  The caller passes a window number and the lookup happens on this side.
rem ---------------------------------------------------------------------------

set "PANE=%~1"
if "%PANE%"=="" set "PANE=Claude"

set "SGR=107;30"
if "%~2"=="1" set "SGR=104;97"
if "%~2"=="2" set "SGR=105;97"
if "%~2"=="3" set "SGR=103;30"
if "%~2"=="4" set "SGR=102;30"

title %PANE%

rem cmd has no escape-character literal, so borrow one from the prompt command.
set "ESC="
for /f "delims=" %%a in ('echo prompt $E^| cmd') do set "ESC=%%a"

echo.
if defined ESC (
    echo  %ESC%[%SGR%m  %PANE%  %ESC%[0m
) else (
    echo  == %PANE% ==
)
echo.

if /i "%~3"=="-noclaude" goto :eof

rem 'call' so control returns here, and to this cmd /k prompt, when Claude exits.
call claude
