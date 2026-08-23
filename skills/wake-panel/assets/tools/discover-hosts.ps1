<#
.SYNOPSIS
    Find machines on the LAN and their MAC addresses, for filling in hosts.json.

.DESCRIPTION
    Sweeps the local /24 to populate the ARP cache, then reports every responding
    host with its MAC and a best-effort vendor guess.

    IMPORTANT: this reports the MAC of whichever interface answered. If a machine
    is on both Wi-Fi and Ethernet you may get the wrong one. Always confirm the
    MAC on the machine itself:  Get-NetAdapter -Physical
    Using a Wi-Fi or virtual adapter's MAC is the most common Wake-on-LAN setup
    mistake - the panel looks fine and silently never wakes anything.

.EXAMPLE
    .\discover-hosts.ps1
    .\discover-hosts.ps1 -Subnet 192.168.4
#>

[CmdletBinding()]
param(
    [string]$Subnet,
    [int]$TimeoutMs = 250
)

if (-not $Subnet) {
    # Pick the adapter that has a DEFAULT GATEWAY. Blocklisting names by hand
    # does not survive contact with a real workstation - VirtualBox Host-Only
    # (192.168.56.x), VMware, Hyper-V, Docker and Tailscale all present as
    # perfectly ordinary IPv4 interfaces, and picking one silently sweeps an
    # empty subnet. Only the real LAN route has a gateway.
    $best = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and
                           $_.IPv4Address.IPAddress -notlike '169.254.*' } |
            Sort-Object { $_.NetAdapter.LinkSpeed } -Descending |
            Select-Object -First 1
    $ip = $best.IPv4Address.IPAddress

    if (-not $ip) {
        # Fallback for hosts where Get-NetIPConfiguration is unavailable (the
        # root/standardcimv2 CIM namespace can be missing in sandboxed shells).
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' -and
                             $_.InterfaceAlias -notmatch 'Tailscale|Loopback|vEthernet|WSL|VirtualBox|VMware|Hyper-V|Docker' } |
              Select-Object -First 1 -ExpandProperty IPAddress
    }
    if (-not $ip) { throw "Could not determine local subnet. Pass -Subnet (e.g. 192.168.1)." }
    $Subnet = ($ip -split '\.')[0..2] -join '.'
    Write-Host "Using $($best.InterfaceAlias ?? 'detected adapter') -> $ip" -ForegroundColor DarkGray
}

Write-Host "Sweeping $Subnet.1-254 ..." -ForegroundColor Cyan

# Fire all pings concurrently; we only care about populating the ARP cache.
$pings = 1..254 | ForEach-Object {
    $p = New-Object System.Net.NetworkInformation.Ping
    [pscustomobject]@{ Ip = "$Subnet.$_"; Task = $p.SendPingAsync("$Subnet.$_", $TimeoutMs) }
}
[void][Threading.Tasks.Task]::WaitAll(@($pings.Task))
Start-Sleep -Milliseconds 400    # let ARP settle

# Vendor prefixes worth recognising when hunting for a NAS or an always-on box.
$oui = @{
    '24:5E:BE' = 'QNAP'; '00:11:32' = 'Synology'; '00:1D:D8' = 'Microsoft'
    'B8:27:EB' = 'Raspberry Pi'; 'DC:A6:32' = 'Raspberry Pi'; 'E4:5F:01' = 'Raspberry Pi'
    '00:0C:29' = 'VMware';   '52:54:00' = 'QEMU/KVM'; '08:00:27' = 'VirtualBox VM'
}

$arp = arp -a | Select-String "$([regex]::Escape($Subnet))\."
$rows = foreach ($line in $arp) {
    $f = ($line -replace '\s+', ' ').Trim() -split ' '
    if ($f.Count -lt 2 -or $f[1] -notmatch '^([0-9a-f]{2}-){5}[0-9a-f]{2}$') { continue }
    $mac = $f[1].ToUpper().Replace('-', ':')
    if ($mac -eq 'FF:FF:FF:FF:FF:FF' -or $mac -like '01:00:5E:*') { continue }

    $name = try { [System.Net.Dns]::GetHostEntry($f[0]).HostName } catch { '' }
    [pscustomobject]@{
        IP     = $f[0]
        MAC    = $mac
        Vendor = $oui[$mac.Substring(0, 8)]
        Name   = $name
    }
}

$rows | Sort-Object { [version]($_.IP) } | Format-Table -AutoSize

Write-Host @"
Next:
  1. Identify your always-on device (NAS / Pi / mini-PC) - it hosts the relay.
  2. For each machine you want to control, CONFIRM its wired MAC on the machine
     itself with:  Get-NetAdapter -Physical      (Windows)
                   ip -br link                    (Linux)
     Do not trust a Wi-Fi MAC here.
"@ -ForegroundColor DarkGray
