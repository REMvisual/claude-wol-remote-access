<#
.SYNOPSIS
    Prepare a Windows machine to be controlled by Wake Panel.

.DESCRIPTION
    Installs/enables OpenSSH Server, authorises the relay's public key with the
    ACL Windows actually requires, disables Fast Startup, installs the telemetry
    collector, and reports Wake-on-LAN readiness.

    Idempotent. DOES NOT reboot, sleep, or shut down - every change applies to
    the running system.

.PARAMETER PublicKey
    One or more public keys to authorise. Pass the relay's key.

.PARAMETER KeepFastStartup
    Skip disabling hibernate/Fast Startup. Only use if you do not care about
    waking this machine from a full shutdown.

.EXAMPLE
    .\setup-host.ps1 -PublicKey 'ssh-ed25519 AAAA... wakepanel'
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$PublicKey,
    [switch]$KeepFastStartup
)

$ErrorActionPreference = 'Stop'

Write-Host "`n=== 1. FAST STARTUP / HIBERNATE ===" -ForegroundColor Cyan
if ($KeepFastStartup) {
    Write-Host "  skipped by request - S5 wake will probably not work" -ForegroundColor Yellow
} else {
    # Fast Startup turns "shutdown" into a hybrid hibernate, which on most NICs
    # drops the Wake-on-LAN arming. Prerequisite for S5 wake ever working.
    # Applies immediately; no restart needed.
    $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
           -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($hb -eq 0) {
        Write-Host "  already disabled" -ForegroundColor Green
    } else {
        powercfg /h off
        Write-Host "  hibernate + Fast Startup disabled" -ForegroundColor Green
    }
}

Write-Host "`n=== 2. OPENSSH SERVER ===" -ForegroundColor Cyan

# Select-Object -First 1: the wildcard can match more than one capability, and
# passing an ARRAY to -Name fails parameter binding with a terminating error.
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue |
       Select-Object -First 1

if (-not $cap) {
    # Never assume the lookup succeeded. If it returns nothing, $cap.State is
    # $null, which is "not Installed", and we would call Add-WindowsCapability
    # with a null name - failing confusingly instead of saying what is wrong.
    Write-Host "  [!!] Could not query Windows capabilities." -ForegroundColor Red
    Write-Host "       'OpenSSH.Server*' matched nothing. This usually means the" -ForegroundColor Yellow
    Write-Host "       shell is not elevated, or DISM/servicing is unavailable." -ForegroundColor Yellow
    Write-Host "       Check by hand:  Get-WindowsCapability -Online -Name 'OpenSSH*'" -ForegroundColor Yellow
    throw "OpenSSH.Server capability not found"
}
Write-Host "  capability: $($cap.Name) [$($cap.State)]" -ForegroundColor DarkGray

if ($cap.State -ne 'Installed') {
    # On a machine that has never had it, this is a Feature-on-Demand: Windows
    # downloads it from Windows Update and runs DISM servicing. That takes
    # MINUTES and prints nothing except a progress bar that often renders over
    # earlier scrollback. Without this warning it looks exactly like a hang -
    # observed on a clean Win11 25H2 install, where it pinned ~2.6 cores for
    # several minutes in total silence.
    Write-Host "  not installed - fetching from Windows Update." -ForegroundColor Yellow
    Write-Host "  This can take 2-5 minutes and shows little output. NOT frozen." -ForegroundColor Yellow
    Write-Host "  Started at $(Get-Date -Format HH:mm:ss)..." -ForegroundColor DarkGray
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # Surface the failure. Without this the terminating error can end the
        # process leaving only a section header on screen, which reads as a
        # hang or a crash and gives the user nothing to act on.
        $r = Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
        $sw.Stop()
        Write-Host "  installed in $([int]$sw.Elapsed.TotalSeconds)s" -ForegroundColor Green
        if ($r.RestartNeeded) { Write-Host "  (a restart is pending, but sshd works now)" -ForegroundColor DarkGray }
    } catch {
        $sw.Stop()
        Write-Host "  [!!] FAILED after $([int]$sw.Elapsed.TotalSeconds)s" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "       OpenSSH ships as a Feature-on-Demand, fetched from Windows Update." -ForegroundColor Yellow
        Write-Host "       It fails on machines where WU is blocked by policy/WSUS, metered," -ForegroundColor Yellow
        Write-Host "       or offline. Options:" -ForegroundColor Yellow
        Write-Host "         - retry (transient WU errors are common)" -ForegroundColor Yellow
        Write-Host "         - check policy:  Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -EA SilentlyContinue" -ForegroundColor Yellow
        Write-Host "         - install Win32-OpenSSH manually from its GitHub release," -ForegroundColor Yellow
        Write-Host "           then re-run this script - it will skip to the key setup." -ForegroundColor Yellow
        throw
    }
} else {
    Write-Host "  already installed" -ForegroundColor Green
}
Set-Service sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Write-Host "  sshd: $((Get-Service sshd).Status), StartType=$((Get-Service sshd).StartType)" -ForegroundColor Green

# GOTCHA: Get-NetFirewallRule can return 0 rules with NO error when the
# root/standardcimv2 CIM namespace is unavailable - it looks exactly like an
# empty rule store, and makes Remove-NetFirewallRule silently no-op. netsh is
# the trustworthy reader here.
$fw = netsh advfirewall firewall show rule name="OpenSSH-Server-In-TCP" 2>&1 | Out-String
if ($fw -match 'No rules match') {
    netsh advfirewall firewall add rule name="OpenSSH-Server-In-TCP" `
        dir=in action=allow protocol=TCP localport=22 profile=any | Out-Null
    Write-Host "  firewall rule created (TCP 22)" -ForegroundColor Green
} else {
    Write-Host "  firewall rule already present" -ForegroundColor Green
}

Write-Host "`n=== 3. AUTHORIZED KEYS ===" -ForegroundColor Cyan
# HARD RULE (Windows OpenSSH): for accounts in the Administrators group, sshd
# IGNORES ~\.ssh\authorized_keys entirely. It reads ONLY this file, and only if
# the ACL grants nothing beyond SYSTEM + Administrators. Wrong file or loose ACL
# means the key is silently rejected with no useful log line. This is the single
# most common reason "key auth just doesn't work" on Windows.
$ak = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
if (-not (Test-Path $ak)) { New-Item -ItemType File -Path $ak -Force | Out-Null }

$existing = @(Get-Content $ak -ErrorAction SilentlyContinue)
foreach ($k in $PublicKey) {
    $k = $k.Trim()
    if (-not $k) { continue }
    if ($existing -contains $k) {
        Write-Host "  present : $($k.Split(' ')[-1])" -ForegroundColor DarkGray
    } else {
        Add-Content -Path $ak -Value $k -Encoding ascii
        Write-Host "  added   : $($k.Split(' ')[-1])" -ForegroundColor Green
    }
}
# Locale-independent SIDs: *S-1-5-32-544 = Administrators, *S-1-5-18 = SYSTEM
icacls $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
Write-Host "  ACL locked to SYSTEM + Administrators" -ForegroundColor Green

Write-Host "`n=== 4. TELEMETRY COLLECTOR ===" -ForegroundColor Cyan
$src = Join-Path $PSScriptRoot 'telemetry.ps1'
$dst = Join-Path $env:USERPROFILE 'telemetry.ps1'
if (Test-Path $src) {
    Copy-Item $src $dst -Force
    Write-Host "  installed: $dst" -ForegroundColor Green
    Write-Host "  put this path in hosts.json as 'collector'" -ForegroundColor DarkGray
} else {
    Write-Host "  telemetry.ps1 not found next to this script - copy it manually" -ForegroundColor Yellow
}

Write-Host "`n=== 5. WAKE-ON-LAN READINESS ===" -ForegroundColor Cyan
Write-Host "  -- wired adapters (use one of THESE MACs in hosts.json) --"
Get-NetAdapter -Physical |
    Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wi-Fi|Wireless' } |
    Select-Object Name, InterfaceDescription, MacAddress, LinkSpeed |
    Format-Table -AutoSize | Out-String | Write-Host

$armed = powercfg /devicequery wake_armed
if ($armed -match 'Ethernet|Realtek|Intel\(R\) Ethernet|I2\d\d') {
    Write-Host "  [OK] a wired NIC is wake-armed -> S3 (sleep) wake will work." -ForegroundColor Green
} else {
    Write-Host "  [!!] no wired NIC is wake-armed - not even S3 wake will work." -ForegroundColor Red
    Write-Host "       Device Manager > Ethernet adapter > Power Management:" -ForegroundColor Yellow
    Write-Host "         tick 'Allow this device to wake the computer'" -ForegroundColor Yellow
    Write-Host "       Advanced tab: 'Wake on Magic Packet' = Enabled" -ForegroundColor Yellow
}

Write-Host @"

  [??] S5 (full shutdown) wake is NOT verified by anything above, and powercfg
       cannot see it. A machine can report every value correct here and still
       fail to wake from a full shutdown - the gate is usually firmware.

       If S3 wake works but S5 does not, go into BIOS and look for:
         'Power On By PCI-E' / 'Wake on PCIe' / 'Resume by PCI-E'  -> Enabled
         'ErP Ready' / 'EuP 2013'                                 -> Disabled
       Note: ErP is the usual internet answer but is frequently NOT the cause.
       Enable the PCI-E option even if ErP is already off.

       Only an actual shutdown -> wake test proves it. Until it passes, leave
       wol_verified: false in hosts.json so the panel blocks shutdown.
"@ -ForegroundColor DarkYellow

Write-Host "=== DONE - nothing was restarted ===`n" -ForegroundColor Cyan
