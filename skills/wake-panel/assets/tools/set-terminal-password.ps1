# set-terminal-password.ps1 - set the break-glass terminal's web password.
#
# Run this locally. It prompts, then pipes the credential straight to the relay
# host over SSH. The plaintext never appears in a transcript, in an argv, or in
# your shell history.
#
# HONEST LIMITATION, and it differs from set-password.py for the panel: ttyd
# takes its credential as a COMMAND-LINE ARGUMENT, so it cannot be a hash. The
# relay host must hold the plaintext, and it is visible in `ps` and
# `docker inspect` ON THAT HOST. Anyone able to read those already has a shell
# there, so the marginal exposure is small -- but it means the TAILNET ACL IS
# THE PRIMARY BOUNDARY here and this password is the second layer, which is the
# reverse of the panel's posture. Scope the ACL to specific devices.

param(
    [string]$Relay      = $(Read-Host 'Relay host (user@host)'),
    [string]$RemoteFile = '$HOME/.terminal/credential'
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 prepends a UTF-8 BOM when piping to a native command
# (here: ssh); pwsh 7 does not. A BOM would land inside the credential string
# and make every login fail with no useful error anywhere. The identical trap
# silently emptied the panel's config and caused a real lockout -- forcing a
# BOM-less encoder makes this behave the same under 5.1 and 7.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

$user = Read-Host -Prompt 'Terminal username'
if ([string]::IsNullOrWhiteSpace($user)) { throw 'Username cannot be empty.' }
if ($user -match ':') { throw 'Username cannot contain a colon - ttyd splits on the first one.' }

$sec  = Read-Host -Prompt 'Terminal password' -AsSecureString
$sec2 = Read-Host -Prompt 'Confirm password'  -AsSecureString

$toPlain = {
    param($s)
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

$p1 = & $toPlain $sec
$p2 = & $toPlain $sec2

if ($p1 -ne $p2)       { throw 'Passwords do not match.' }
if ($p1.Length -lt 12) { throw 'Use at least 12 characters - this unlocks a root shell.' }

# `tr` strips any CR/LF the pipe adds; the launcher does CRED=$(cat ...) which
# would otherwise carry a stray carriage return straight into ttyd's
# --credential, giving a login that can never succeed.
$dir    = Split-Path -Parent ($RemoteFile -replace '\\', '/')
$remote = "mkdir -p $dir && chmod 700 $dir && tr -d '\r\n' > $RemoteFile && chmod 600 $RemoteFile && wc -c < $RemoteFile"
$cred   = "$user`:$p1"

# Count BYTES, not characters. `wc -c` reports bytes, so any non-ASCII character
# in the password would otherwise read as a corrupt write and send you hunting
# for a BOM that isn't there.
$expected = [Text.Encoding]::UTF8.GetByteCount($cred)

$written = $cred | ssh $Relay $remote

$p1 = $null; $p2 = $null; $cred = $null; [GC]::Collect()

Write-Host ''
if ([int]$written.Trim() -eq $expected) {
    Write-Host "OK - credential written ($expected bytes, as expected)." -ForegroundColor Green
    Write-Host "Now start it:  ssh $Relay <path>/terminal-run.sh"
} else {
    Write-Host "MISMATCH - wrote $($written.Trim()) bytes, expected $expected." -ForegroundColor Red
    Write-Host 'Likely a BOM or a stray newline. Do NOT start the terminal until this reads clean.'
}
