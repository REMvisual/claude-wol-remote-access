#!/bin/sh
# telemetry.sh - emit this machine's vitals as a single JSON line.
#
# Linux counterpart to telemetry.ps1. Runs ON the target; the relay invokes it
# over SSH and parses stdout. POSIX sh, no dependencies beyond coreutils; every
# section degrades to null rather than failing the payload.

set -u

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

HOSTNAME_=$(hostname 2>/dev/null || echo unknown)
UPTIME_S=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)

# CPU: one delta sample of /proc/stat. Instantaneous "usage" from a single read
# is meaningless - it reports an average since boot.
read_cpu() { awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print idle, total}' /proc/stat; }
set -- $(read_cpu); IDLE1=$1; TOTAL1=$2
sleep 0.3
set -- $(read_cpu); IDLE2=$1; TOTAL2=$2
DT=$((TOTAL2 - TOTAL1)); DI=$((IDLE2 - IDLE1))
CPU_PCT=0
[ "$DT" -gt 0 ] && CPU_PCT=$(( (100 * (DT - DI)) / DT ))

MEM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_AVAIL_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
if [ -z "${MEM_AVAIL_KB:-}" ]; then
    # MemAvailable is absent on kernels older than 3.14 and on some emulated
    # /proc filesystems. Without this fallback the empty value becomes 0, so
    # used == total and the panel shows a permanent, alarming 100% RAM bar.
    MEM_AVAIL_KB=$(awk '/^(MemFree|Buffers|Cached):/{s+=$2} END{print s+0}' /proc/meminfo 2>/dev/null)
fi
[ -z "${MEM_AVAIL_KB:-}" ] && MEM_AVAIL_KB=0
[ -z "${MEM_TOTAL_KB:-}" ] && MEM_TOTAL_KB=0
RAM_TOT=$(awk -v k="$MEM_TOTAL_KB" 'BEGIN{printf "%.1f", k/1048576}')
RAM_USED=$(awk -v t="$MEM_TOTAL_KB" -v a="$MEM_AVAIL_KB" 'BEGIN{printf "%.1f", (t-a)/1048576}')

CPU_NAME=$(awk -F: '/^model name/{gsub(/^ /,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
[ -z "${CPU_NAME:-}" ] && CPU_NAME="unknown"

# GPU via NVML, same source nvidia-smi and every monitoring tool reads.
GPU_JSON=null
if command -v nvidia-smi >/dev/null 2>&1; then
    G=$(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,fan.speed \
                   --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -n "$G" ]; then
        GPU_JSON=$(printf '%s' "$G" | awk -F', *' '{
            fan = ($7 ~ /^[0-9]+$/) ? $7 : "null"
            printf "{\"name\":\"%s\",\"temp_c\":%d,\"util_pct\":%d,\"vram_used\":%d,\"vram_tot\":%d,\"power_w\":%s,\"fan_pct\":%s}",
                   $1,$2,$3,$4,$5,$6,fan
        }')
    fi
fi

# CPU temperature: hwmon is built in on Linux, so unlike Windows this needs no
# extra monitoring app. Prefer a package/composite sensor.
LHM_JSON=null
for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] || continue
    T=$(cat "$z" 2>/dev/null)
    case "$T" in ''|*[!0-9]*) continue ;; esac
    LHM_JSON=$(awk -v t="$T" 'BEGIN{printf "{\"cpu_c\":%.1f,\"board_c\":null,\"count\":1}", t/1000}')
    break
done

# Disks: real filesystems only.
DISKS=$(df -PBG 2>/dev/null | awk 'NR>1 && $1 ~ /^\/dev\// {
    gsub(/G/,"",$2); gsub(/G/,"",$4)
    printf "%s{\"drive\":\"%s\",\"free_gb\":%d,\"total_gb\":%d}", (n++?",":""), $6, $4, $2
}')

printf '{"host":"%s","ok":true,"uptime_s":%s,"cpu_name":"%s","cpu_pct":%s,' \
       "$(json_escape "$HOSTNAME_")" "$UPTIME_S" "$(json_escape "$CPU_NAME")" "$CPU_PCT"
printf '"ram_used_gb":%s,"ram_tot_gb":%s,"gpu":%s,"gpu_procs":[],"workloads":[],' \
       "$RAM_USED" "$RAM_TOT" "$GPU_JSON"
printf '"lhm":%s,"ollama":[],"disks":[%s]}\n' "$LHM_JSON" "${DISKS:-}"
