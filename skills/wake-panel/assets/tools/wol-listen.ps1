<#
.SYNOPSIS
    Listen for a Wake-on-LAN magic packet and verify it arrives correctly addressed.

.DESCRIPTION
    Run this ON a target machine, then send it a wake from the panel. It proves
    the packet actually crosses your network and is addressed to THIS machine -
    without powering anything off.

    This separates the two failure modes that otherwise look identical:

      packet NEVER ARRIVES  -> a network problem. Docker bridge networking,
                               relay on the wrong segment, wrong broadcast
                               address, a switch or AP dropping broadcast.
      packet ARRIVES, machine still won't wake
                            -> a firmware/NIC problem. BIOS 'Power On By PCI-E',
                               Fast Startup, or the adapter not wake-armed.

    Without this you cannot tell them apart, and people burn hours in BIOS for
    what is actually a container networking mistake.

    Needs elevation only to add a temporary inbound firewall rule.

.EXAMPLE
    .\wol-listen.ps1
    .\wol-listen.ps1 -TimeoutSec 120
#>

[CmdletBinding()]
param(
    [int]$Port = 9,
    [int]$TimeoutSec = 60,
    [switch]$NoFirewallRule
)

$ErrorActionPreference = 'Stop'
$ruleName = "WakePanel-WoL-Listen-Temp"
$ruleAdded = $false

# Windows blocks unsolicited inbound UDP on the Public profile, which is where
# fresh installs put every new network. Without a rule the packet is dropped by
# the firewall and this reports a false "never arrived".
if (-not $NoFirewallRule) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow `
              protocol=UDP localport=$Port profile=any | Out-Null
        $ruleAdded = $true
        Write-Host "temporary firewall rule added for UDP $Port" -ForegroundColor DarkGray
    } else {
        Write-Host "NOT elevated - cannot open UDP $Port. If nothing arrives, that" -ForegroundColor Yellow
        Write-Host "may be the firewall rather than the network. Re-run as admin." -ForegroundColor Yellow
    }
}

$localMacs = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
              Where-Object Status -eq 'Up').MacAddress |
             ForEach-Object { $_ -replace '[^0-9A-Fa-f]', '' } | ForEach-Object { $_.ToUpper() }

Write-Host "`nListening on UDP $Port for ${TimeoutSec}s. Send a wake now.`n" -ForegroundColor Cyan

$udp = New-Object System.Net.Sockets.UdpClient($Port)
$udp.Client.ReceiveTimeout = $TimeoutSec * 1000
$ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

try {
    while ($true) {
        try { $data = $udp.Receive([ref]$ep) } catch [System.Net.Sockets.SocketException] {
            Write-Host "TIMEOUT - no packet arrived in ${TimeoutSec}s." -ForegroundColor Red
            Write-Host "  The packet is not reaching this machine at all. Look at the" -ForegroundColor Yellow
            Write-Host "  NETWORK, not the BIOS: bridge-mode Docker, wrong subnet, or" -ForegroundColor Yellow
            Write-Host "  broadcast being dropped between relay and target." -ForegroundColor Yellow
            break
        }

        # A magic packet is exactly 102 bytes: 6x 0xFF then the target MAC x16.
        $isMagic = $data.Length -eq 102 -and (0..5 | ForEach-Object { $data[$_] } | Where-Object { $_ -ne 0xFF }).Count -eq 0
        if (-not $isMagic) {
            Write-Host "packet from $($ep.Address): $($data.Length) bytes - not a magic packet, ignoring" -ForegroundColor DarkGray
            continue
        }

        $mac = (6..11 | ForEach-Object { '{0:X2}' -f $data[$_] }) -join ''
        $pretty = ($mac -split '(..)' -ne '') -join ':'
        Write-Host "MAGIC PACKET RECEIVED" -ForegroundColor Green
        Write-Host "  from        : $($ep.Address)"
        Write-Host "  length      : $($data.Length) bytes (correct)"
        Write-Host "  target MAC  : $pretty"

        if ($localMacs -contains $mac) {
            Write-Host "  [OK] addressed to THIS machine.`n" -ForegroundColor Green
            Write-Host "  Network path is proven. If it still will not wake from a full" -ForegroundColor DarkGray
            Write-Host "  shutdown, the problem is firmware - see TROUBLESHOOTING." -ForegroundColor DarkGray
        } else {
            Write-Host "  [!!] NOT one of this machine's MACs." -ForegroundColor Red
            Write-Host "       This machine's wired MACs: $($localMacs -join ', ')" -ForegroundColor Yellow
            Write-Host "       Fix the 'mac' field in hosts.json - a wrong MAC is the" -ForegroundColor Yellow
            Write-Host "       most common Wake-on-LAN setup error." -ForegroundColor Yellow
        }
        break
    }
} finally {
    $udp.Close()
    if ($ruleAdded) {
        netsh advfirewall firewall delete rule name="$ruleName" | Out-Null
        Write-Host "temporary firewall rule removed" -ForegroundColor DarkGray
    }
}
