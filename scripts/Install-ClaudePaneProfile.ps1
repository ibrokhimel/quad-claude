<#
.SYNOPSIS
    Installs the 'Claude Pane' Windows Terminal profile as a fragment extension.

.DESCRIPTION
    Windows Terminal reads extra profiles from JSON "fragments" dropped into

        %LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\<app>\<file>.json

    Using a fragment instead of editing settings.json means your own settings
    file is never touched, and uninstalling is deleting one file.

    The profile exists to control two things the wt.exe command line cannot:

      closeOnExit              What a pane does when its process ends. Without
                               this you get the "[process exited] ... you can
                               configure this in your profile settings" notice
                               left sitting in the pane.
      suppressApplicationTitle Stops Claude from renaming the pane, so the name
                               you gave the pane is the name that stays on it.

.PARAMETER CloseOnExit
    graceful (default) - close the pane on a clean exit, keep it open (with the
                         exit notice) if the process crashed or was killed, so
                         you can still read what happened.
    always             - always close the pane, no notice, ever. Quietest, but
                         a crashed session vanishes before you can read it.
    never              - always keep the pane and show the notice.

.PARAMETER Uninstall
    Remove the fragment.

.NOTES
    Windows Terminal loads fragments at startup. If Terminal is already running,
    the profile becomes available after every Terminal window has been closed
    once. Open-QuadClaude.ps1 detects this and falls back cleanly meanwhile.
#>
[CmdletBinding()]
param(
    [ValidateSet('graceful', 'always', 'never')]
    [string] $CloseOnExit = 'graceful',
    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$FragmentDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\quad-claude'
$FragmentPath = Join-Path $FragmentDir 'claude-pane.json'
$ProfileName  = 'Claude Pane'

if ($Uninstall) {
    if (Test-Path -LiteralPath $FragmentPath) {
        Remove-Item -LiteralPath $FragmentPath -Force
        Write-Host "Removed $FragmentPath"
    } else {
        Write-Host "Nothing to remove; $FragmentPath does not exist."
    }
    return
}

$fragment = [ordered]@{
    profiles = @(
        [ordered]@{
            name                     = $ProfileName
            commandline              = 'powershell.exe -NoLogo -NoExit'
            closeOnExit              = $CloseOnExit
            suppressApplicationTitle = $true
            historySize              = 20000
            padding                  = '8, 8, 8, 8'
        }
    )
}

$json = ($fragment | ConvertTo-Json -Depth 8)

if (-not (Test-Path -LiteralPath $FragmentDir)) {
    New-Item -ItemType Directory -Path $FragmentDir -Force | Out-Null
}

# Only write when the content actually changed. Rewriting an identical file
# would bump its timestamp, and Open-QuadClaude.ps1 uses that timestamp to
# decide whether the running Terminal has already picked the profile up.
$existing = $null
if (Test-Path -LiteralPath $FragmentPath) {
    $existing = Get-Content -LiteralPath $FragmentPath -Raw
}

if ($existing -ne $null -and $existing.Trim() -eq $json.Trim()) {
    Write-Host "Profile '$ProfileName' already installed and up to date."
} else {
    Set-Content -LiteralPath $FragmentPath -Value $json -Encoding UTF8
    $verb = if ($existing) { 'Updated' } else { 'Installed' }
    Write-Host "$verb profile '$ProfileName' (closeOnExit=$CloseOnExit)"
    Write-Host "  $FragmentPath"

    if (Get-Process WindowsTerminal -ErrorAction SilentlyContinue) {
        Write-Host ''
        Write-Warning "Windows Terminal is running, so it has not loaded this profile yet. It takes effect once every Terminal window has been closed. Until then the grid still opens, using the default profile."
    }
}
