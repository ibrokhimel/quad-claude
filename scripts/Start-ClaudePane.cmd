@echo off
rem ---------------------------------------------------------------------------
rem  Start-ClaudePane.cmd  <name> <1-4> [skip|safe|none]
rem
rem  Startup script for one Claude window: colour the terminal, name the
rem  console, print a banner, then start Claude.
rem
rem    <name>    window name, shown in the title bar, prompt and banner
rem    <1-4>     window number, selects the colour theme
rem    skip      start Claude with --dangerously-skip-permissions (default)
rem    safe      start Claude normally, with permission prompts
rem    none      do not start Claude, just leave a shell (layout testing)
rem
rem  Lives in its own file rather than inline in the wt.exe command line because
rem  wt.exe splits its command line on ';' even inside a quoted argument, which
rem  shreds any inline multi-statement command. The colour values below are the
rem  same story: ANSI codes and OSC sequences are full of semicolons, so they
rem  could never be passed through wt.exe. The caller passes a window number and
rem  every lookup happens on this side.
rem
rem  Two different escape-sequence families are used here:
rem    SGR  ESC[<n>m       colours the TEXT that follows. 30-37 foreground,
rem                        90-97 bright foreground, 40-47 and 100-107 the
rem                        background, 1 bold, 0 reset.
rem    OSC  ESC]<n>;<v>ST  reconfigures the TERMINAL itself - which RGB values
rem                        the sixteen colour slots actually are, plus the
rem                        default foreground, background and cursor.
rem  SGR picks a slot, OSC decides what colour that slot is.
rem ---------------------------------------------------------------------------

setlocal EnableDelayedExpansion

set "PANE=%~1"
if "%PANE%"=="" set "PANE=Claude"

set "MODE=%~3"
if "%MODE%"=="" set "MODE=skip"

rem --- per-window theme ------------------------------------------------------
rem BG/CUR are OSC colours (the window). SGR is the banner's colour pair.
rem ACCENT is an SGR foreground code used for this window's prompt.
set "BG=#101418"
set "CUR=#e6edf3"
set "SGR=107;30"
set "ACCENT=97"
if "%~2"=="1" ( set "BG=#0d1b2a" & set "CUR=#61afef" & set "SGR=104;97" & set "ACCENT=94" )
if "%~2"=="2" ( set "BG=#1e1030" & set "CUR=#ff79c6" & set "SGR=105;97" & set "ACCENT=95" )
if "%~2"=="3" ( set "BG=#2a1e0a" & set "CUR=#f1fa8c" & set "SGR=103;30" & set "ACCENT=93" )
if "%~2"=="4" ( set "BG=#0b2318" & set "CUR=#50fa7b" & set "SGR=102;30" & set "ACCENT=92" )

rem Colour the shell prompt, so the window is not white-on-tint once Claude
rem exits. $E is cmd's own escape character inside a PROMPT string, so this
rem needs no ESC variable: $E[<n>m sets colour, $E[0m resets, $P is the path
rem and $G is the '>'.
set "NEWPROMPT=$E[1;%ACCENT%m%PANE%$E[0m $E[90m$P$E[%ACCENT%m$G$E[0m "

rem cmd has no escape-character literal, so borrow one from the prompt command.
set "ESC="
for /f "delims=" %%a in ('echo prompt $E^| cmd') do set "ESC=%%a"

title %PANE%

if not defined ESC goto :no_color

rem --- vivid 16-colour palette, shared by all four windows -------------------
rem This is what makes Claude's output colourful instead of white on black:
rem every coloured thing a CLI prints resolves through these sixteen slots.
set "OSC=!ESC!]"
set "ST=!ESC!\"

set "P="
set "P=!P!!OSC!4;0;#21262d!ST!"
set "P=!P!!OSC!4;1;#ff5555!ST!"
set "P=!P!!OSC!4;2;#50fa7b!ST!"
set "P=!P!!OSC!4;3;#f1fa8c!ST!"
set "P=!P!!OSC!4;4;#61afef!ST!"
set "P=!P!!OSC!4;5;#ff79c6!ST!"
set "P=!P!!OSC!4;6;#8be9fd!ST!"
set "P=!P!!OSC!4;7;#e6edf3!ST!"
set "P=!P!!OSC!4;8;#6272a4!ST!"
set "P=!P!!OSC!4;9;#ff6e6e!ST!"
set "P=!P!!OSC!4;10;#69ff94!ST!"
set "P=!P!!OSC!4;11;#ffffa5!ST!"
set "P=!P!!OSC!4;12;#7aa2f7!ST!"
set "P=!P!!OSC!4;13;#ff92df!ST!"
set "P=!P!!OSC!4;14;#a4ffff!ST!"
set "P=!P!!OSC!4;15;#ffffff!ST!"
set "P=!P!!OSC!10;#e6edf3!ST!"
set "P=!P!!OSC!11;!BG!!ST!"
set "P=!P!!OSC!12;!CUR!!ST!"

<nul set /p "=!P!"
cls

echo.
echo  !ESC![%SGR%m  %PANE%  !ESC![0m
echo.
goto :launch

:no_color
echo.
echo  == %PANE% ==
echo.

:launch
rem Carry PROMPT out past endlocal, so the colour survives into the interactive
rem shell that cmd /k leaves behind after Claude exits. Both values on this line
rem are expanded before endlocal runs, which is what makes the idiom work.
endlocal & set "PROMPT=%NEWPROMPT%" & set "MODE=%MODE%"

if /i "%MODE%"=="none" goto :eof

rem 'call' so control returns here, and to this cmd /k prompt, when Claude exits.
if /i "%MODE%"=="safe" (
    call claude
) else (
    call claude --dangerously-skip-permissions
)
