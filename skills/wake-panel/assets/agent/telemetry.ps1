# telemetry.ps1 - emit this machine's vitals as a single JSON line.
#
# Runs ON the target machine; the relay invokes it over SSH and parses stdout.
# It queries its own localhost, so LibreHardwareMonitor / Ollama / llama.cpp
# never need to listen on the network - SSH stays the only remote surface.
#
# Every section is independently guarded: no GPU, no LHM, no inference server
# yields null for that section rather than failing the whole payload.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# Ports to check for a local Ollama. Both, because some setups run a proxy or
# router on the default 11434 that forwards to another machine - querying it
# would report a DIFFERENT computer's models on this machine's card.
$OllamaPorts = @(11435, 11434)
$LhmPort     = 8085

function Test-LocalPort {
    # Invoke-RestMethod against a dead local port burns its FULL timeout, which
    # made each poll take ~5s of its 8s budget. A closed port on loopback RSTs
    # immediately, so a 200ms connect separates "absent" from "slow" reliably.
    param([int]$Port)
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(200)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

function Get-Gpu {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $null }
    $raw = & nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,fan.speed `
                        --format=csv,noheader,nounits 2>$null
    if (-not $raw) { return $null }
    $f = ($raw | Select-Object -First 1) -split '\s*,\s*'
    if ($f.Count -lt 6) { return $null }
    [pscustomobject]@{
        name      = $f[0]
        temp_c    = [int]$f[1]
        util_pct  = [int]$f[2]
        vram_used = [int]$f[3]
        vram_tot  = [int]$f[4]
        power_w   = [double]$f[5]
        fan_pct   = if ($f[6] -match '^\d+$') { [int]$f[6] } else { $null }
    }
}

$script:ComputeApps = $null
function Get-ComputeApps {
    if ($null -ne $script:ComputeApps) { return $script:ComputeApps }
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        $script:ComputeApps = @(); return $script:ComputeApps
    }
    $script:ComputeApps = @(& nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>$null)
    return $script:ComputeApps
}

function Get-GpuProcs {
    # ALLOWLIST, not a denylist. On a real desktop practically everything holds
    # a graphics context - the lock screen, mouse drivers, antivirus, browsers -
    # so enumerating noise is a losing game. Match what we care about instead.
    $interesting = 'llama|ollama|python|comfy|blender|vllm|kobold|lmstudio|' +
                   'stable|invoke|forge|torch|automatic|unreal|resolve|ffmpeg'
    $names = Get-ComputeApps | ForEach-Object {
        $n = [System.IO.Path]::GetFileNameWithoutExtension((($_ -split ',')[1]).Trim())
        if ($n -and $n -match $interesting) { $n }
    }
    @($names | Select-Object -Unique)
}

function Get-GpuWorkloads {
    # Process names ("llama-server", "python") don't say WHAT is loaded.
    # Inference servers expose an HTTP API, so ask them. Ports are discovered
    # from the owning PID rather than hardcoded, since they vary per setup.
    $apps = Get-ComputeApps
    if (-not $apps) { return @() }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $apps) {
        $parts = $line -split ','
        if ($parts.Count -lt 2) { continue }
        $procId = $parts[0].Trim()
        $name   = [System.IO.Path]::GetFileNameWithoutExtension($parts[1].Trim())
        if ($name -notin @('llama-server', 'python', 'pythonw', 'ollama', 'vllm')) { continue }

        $ports = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                 Where-Object OwningProcess -eq $procId |
                 Select-Object -ExpandProperty LocalPort -Unique
        foreach ($port in $ports) {
            $detail = $null

            # OpenAI-compatible (llama.cpp, vLLM, TGI). llama.cpp answers with
            # {models:[{name}]}, the OpenAI spec with {data:[{id}]} - take both.
            try {
                $m = Invoke-RestMethod "http://127.0.0.1:$port/v1/models" -TimeoutSec 2
                if ($m.models -and $m.models[0].name) { $detail = $m.models[0].name }
                elseif ($m.data -and $m.data[0].id)   { $detail = $m.data[0].id }
            } catch { }

            if (-not $detail) {
                try {
                    $s = Invoke-RestMethod "http://127.0.0.1:$port/system_stats" -TimeoutSec 2
                    if ($s.system.comfyui_version) { $detail = "ComfyUI $($s.system.comfyui_version)" }
                } catch { }
            }

            # Ollama spawns its own llama-server per model on ephemeral ports,
            # and those report the on-disk blob path as the model id
            # ("...\.ollama\models\blobs\sha256-a3de86..."). Useless to display,
            # and Ollama's own API already names them properly.
            if ($detail -and ($detail -match '[\\/]' -or $detail -match 'sha256-')) { $detail = $null }

            if ($detail) {
                $out.Add([pscustomobject]@{ proc = $name; port = [int]$port; detail = $detail })
                break
            }
        }
    }
    @($out)
}

function Get-Lhm {
    # LibreHardwareMonitor's web server - the only straightforward source of CPU
    # and motherboard temps on Windows. Must be the STANDALONE app running
    # elevated with its web server enabled. FanControl does NOT provide this: it
    # links the LHM library but starts no server. Absent is fine; the row hides.
    if (-not (Test-LocalPort $LhmPort)) { return $null }
    try { $d = Invoke-RestMethod "http://127.0.0.1:$LhmPort/data.json" -TimeoutSec 3 } catch { return $null }
    if (-not $d) { return $null }

    $temps = [System.Collections.Generic.List[object]]::new()
    function Walk($node, $trail) {
        $name = if ($node.Text) { $node.Text } else { '' }
        $path = if ($trail) { "$trail/$name" } else { $name }
        if ($node.Value -and $node.Value -match '^\s*([\d.]+)\s*°?C') {
            $temps.Add([pscustomobject]@{ path = $path; c = [double]$Matches[1] })
        }
        foreach ($c in $node.Children) { Walk $c $path }
    }
    Walk $d ''
    if ($temps.Count -eq 0) { return $null }

    $cpu = $temps | Where-Object { $_.path -match 'CPU (Package|Total|Die)' } | Select-Object -First 1
    if (-not $cpu) { $cpu = $temps | Where-Object { $_.path -match 'CPU' } | Select-Object -First 1 }
    $mb  = $temps | Where-Object { $_.path -match 'Motherboard|System|Mainboard' } | Select-Object -First 1

    [pscustomobject]@{
        cpu_c   = if ($cpu) { [math]::Round($cpu.c, 1) } else { $null }
        board_c = if ($mb)  { [math]::Round($mb.c, 1) }  else { $null }
        count   = $temps.Count
    }
}

function Get-Ollama {
    $ps = $null
    foreach ($port in $OllamaPorts) {
        if (-not (Test-LocalPort $port)) { continue }
        try {
            $r = Invoke-RestMethod "http://127.0.0.1:$port/api/ps" -TimeoutSec 3
            if ($r -and $r.models) { $ps = $r; break }
        } catch { }
    }
    if (-not $ps -or -not $ps.models) { return @() }
    @($ps.models | ForEach-Object {
        [pscustomobject]@{ name = $_.name; vram_mib = [int]($_.size_vram / 1MB) }
    })
}

$os   = Get-CimInstance Win32_OperatingSystem
$boot = $os.LastBootUpTime
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1

$payload = [ordered]@{
    host        = $env:COMPUTERNAME
    ok          = $true
    booted_at   = if ($boot) { $boot.ToUniversalTime().ToString('o') } else { $null }
    uptime_s    = if ($boot) { [int]((Get-Date) - $boot).TotalSeconds } else { $null }
    cpu_name    = if ($cpu) { $cpu.Name.Trim() } else { $null }
    cpu_pct     = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    ram_used_gb = if ($os) { [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB), 1) } else { $null }
    ram_tot_gb  = if ($os) { [math]::Round(($os.TotalVisibleMemorySize / 1MB), 1) } else { $null }
    gpu         = Get-Gpu
    gpu_procs   = @(Get-GpuProcs)
    workloads   = @(Get-GpuWorkloads)
    lhm         = Get-Lhm
    ollama      = @(Get-Ollama)
    disks       = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
                      [pscustomobject]@{
                          drive    = $_.DeviceID
                          free_gb  = [math]::Round($_.FreeSpace / 1GB)
                          total_gb = [math]::Round($_.Size / 1GB)
                      } })
}

# -Compress keeps it to one line, which the relay reads as the last line of
# stdout - impossible to confuse with a partial read or a stray warning.
$payload | ConvertTo-Json -Depth 6 -Compress
