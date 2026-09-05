#!/usr/bin/env bash
# Per-app cgroup v2 metrics in the textfile format Fluent Bit's embedded
# node_exporter_metrics already reads.
#
# The `processes` collector only counts processes by state. Since every app
# runs under its own MemoryMax, MemorySwapMax and CPUQuota, without this
# throttling, swap usage and OOM kills per app are invisible.
#
# Swap and PSI are the leading indicators: a cgroup pushed into swap, or one
# whose memory pressure is climbing, is minutes away from an OOM kill. Both
# are here so the alert fires before the kill, not after it.

set -uo pipefail

CGROOT=/sys/fs/cgroup/apps.slice
OUTDIR=/var/lib/node_exporter/textfile
TMP=$(mktemp "$OUTDIR/.app_metrics.XXXXXX")

kv() { awk -v k="$2" '$1==k{print $2; exit}' "$1" 2>/dev/null; }

# some avg10=0.42 avg60=... -> 0.42
psi() { awk -v t="$2" '$1==t{sub(/^avg10=/,"",$2); print $2; exit}' "$1" 2>/dev/null; }

{
  echo "# HELP app_mem_bytes Current cgroup memory"
  echo "# TYPE app_mem_bytes gauge"
  echo "# HELP app_mem_max_bytes Hard memory ceiling"
  echo "# TYPE app_mem_max_bytes gauge"
  echo "# HELP app_mem_pct Percent of memory.max in use"
  echo "# TYPE app_mem_pct gauge"
  echo "# HELP app_swap_bytes Swap in use by the cgroup"
  echo "# TYPE app_swap_bytes gauge"
  echo "# HELP app_swap_max_bytes MemorySwapMax for the cgroup"
  echo "# TYPE app_swap_max_bytes gauge"
  echo "# HELP app_swap_pct Percent of MemorySwapMax in use"
  echo "# TYPE app_swap_pct gauge"
  echo "# HELP app_swap_fail_total Swap allocations refused because the limit was reached"
  echo "# TYPE app_swap_fail_total counter"
  echo "# HELP app_mem_pressure_avg10 Share of the last 10s stalled on memory (some/full)"
  echo "# TYPE app_mem_pressure_avg10 gauge"
  echo "# HELP app_io_pressure_avg10 Share of the last 10s stalled on IO"
  echo "# TYPE app_io_pressure_avg10 gauge"
  echo "# HELP app_cpu_pressure_avg10 Share of the last 10s stalled on CPU"
  echo "# TYPE app_cpu_pressure_avg10 gauge"
  echo "# HELP app_cpu_pct CPU over the last interval (100 = one core)"
  echo "# TYPE app_cpu_pct gauge"
  echo "# HELP app_cpu_throttled_pct Share of the interval barred by CPUQuota"
  echo "# TYPE app_cpu_throttled_pct gauge"
  echo "# HELP app_cpu_throttled_periods_total Periods in which CPUQuota barred the app"
  echo "# TYPE app_cpu_throttled_periods_total counter"
  echo "# HELP app_oom_kills_total Processes killed by the OOM killer inside the cgroup"
  echo "# TYPE app_oom_kills_total counter"
  echo "# HELP app_mem_events_high_total Times the cgroup went over MemoryHigh"
  echo "# TYPE app_mem_events_high_total counter"

  for cg in "$CGROOT"/dotnet-app@*.service; do
    [ -d "$cg" ] || continue
    unit=$(basename "$cg"); app=${unit#dotnet-app@}; app=${app%.service}
    lbl="app=\"${app}\""

    mem_cur=$(cat "$cg/memory.current" 2>/dev/null || echo 0)
    mem_max=$(cat "$cg/memory.max" 2>/dev/null || echo max)
    swap_cur=$(cat "$cg/memory.swap.current" 2>/dev/null || echo 0)
    swap_max=$(cat "$cg/memory.swap.max" 2>/dev/null || echo max)

    # memory.events oom_kill proves an OOM happened INSIDE the app's limit --
    # different from a host OOM, which shows up in the journal.
    oom_kill=$(kv "$cg/memory.events" oom_kill); oom_kill=${oom_kill:-0}
    mem_high=$(kv "$cg/memory.events" high); mem_high=${mem_high:-0}
    # A non-zero `fail` means the app wanted swap and MemorySwapMax refused
    # it. The next step is reclaim it cannot satisfy, then the OOM killer.
    swap_fail=$(kv "$cg/memory.swap.events" fail); swap_fail=${swap_fail:-0}

    usage_usec=$(kv "$cg/cpu.stat" usage_usec); usage_usec=${usage_usec:-0}
    throttled_usec=$(kv "$cg/cpu.stat" throttled_usec); throttled_usec=${throttled_usec:-0}
    nr_throttled=$(kv "$cg/cpu.stat" nr_throttled); nr_throttled=${nr_throttled:-0}

    sf="/run/cgroup-textfile-exporter/${app}.state"
    mkdir -p "$(dirname "$sf")"
    prev_usage=0; prev_ts=0; prev_thr_usec=0
    # shellcheck disable=SC1090
    [ -f "$sf" ] && . "$sf"
    now=$(date +%s)
    dt=$((now - prev_ts))
    if [ "$dt" -gt 0 ] && [ "$prev_usage" -gt 0 ]; then
      d_usage=$((usage_usec - prev_usage)); [ "$d_usage" -lt 0 ] && d_usage=0
      cpu_pct=$(awk -v d="$d_usage" -v t="$dt" 'BEGIN{printf "%.1f", (d/1000000.0)/t*100}')
      d_thr=$((throttled_usec - prev_thr_usec)); [ "$d_thr" -lt 0 ] && d_thr=0
      thr_pct=$(awk -v d="$d_thr" -v t="$dt" 'BEGIN{printf "%.1f", (d/1000000.0)/t*100}')
    else
      cpu_pct=0; thr_pct=0
    fi
    printf 'prev_usage=%s\nprev_ts=%s\nprev_thr_usec=%s\n' \
      "$usage_usec" "$now" "$throttled_usec" > "$sf"

    if [ "$mem_max" = "max" ]; then
      mem_pct=0; mem_max_out=0
    else
      mem_max_out=$mem_max
      mem_pct=$(awk -v c="$mem_cur" -v m="$mem_max" 'BEGIN{ if (m>0) printf "%.1f", c/m*100; else print 0 }')
    fi

    if [ "$swap_max" = "max" ]; then
      swap_pct=0; swap_max_out=0
    else
      swap_max_out=$swap_max
      swap_pct=$(awk -v c="$swap_cur" -v m="$swap_max" 'BEGIN{ if (m>0) printf "%.1f", c/m*100; else print 0 }')
    fi

    echo "app_mem_bytes{${lbl}} ${mem_cur}"
    echo "app_mem_max_bytes{${lbl}} ${mem_max_out}"
    echo "app_mem_pct{${lbl}} ${mem_pct}"
    echo "app_swap_bytes{${lbl}} ${swap_cur}"
    echo "app_swap_max_bytes{${lbl}} ${swap_max_out}"
    echo "app_swap_pct{${lbl}} ${swap_pct}"
    echo "app_swap_fail_total{${lbl}} ${swap_fail}"
    echo "app_cpu_pct{${lbl}} ${cpu_pct}"
    echo "app_cpu_throttled_pct{${lbl}} ${thr_pct}"
    echo "app_cpu_throttled_periods_total{${lbl}} ${nr_throttled}"
    echo "app_oom_kills_total{${lbl}} ${oom_kill}"
    echo "app_mem_events_high_total{${lbl}} ${mem_high}"

    for res in memory io cpu; do
      f="$cg/${res}.pressure"
      [ -r "$f" ] || continue
      case $res in memory) m=mem ;; *) m=$res ;; esac
      for kind in some full; do
        v=$(psi "$f" "$kind")
        [ -n "$v" ] && echo "app_${m}_pressure_avg10{${lbl},kind=\"${kind}\"} ${v}"
      done
    done
  done

  # Host swap and PSI. node_exporter's meminfo gives swap totals and vmstat
  # gives the page-in/page-out counters; neither gives pressure, which is the
  # number that moves first.
  echo "# HELP host_pressure_avg10 Share of the last 10s the host stalled on a resource"
  echo "# TYPE host_pressure_avg10 gauge"
  for res in memory io cpu; do
    f="/proc/pressure/${res}"
    [ -r "$f" ] || continue
    for kind in some full; do
      v=$(psi "$f" "$kind")
      [ -n "$v" ] && echo "host_pressure_avg10{resource=\"${res}\",kind=\"${kind}\"} ${v}"
    done
  done

  echo "# HELP host_swap_used_bytes Swap in use on the host"
  echo "# TYPE host_swap_used_bytes gauge"
  echo "# HELP host_swap_pct Percent of total swap in use"
  echo "# TYPE host_swap_pct gauge"
  awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2}
       END{ u=(t-f)*1024;
            printf "host_swap_used_bytes %d\n", u;
            if (t>0) printf "host_swap_pct %.1f\n", (t-f)/t*100; else print "host_swap_pct 0" }' \
      /proc/meminfo
} > "$TMP"

chmod 644 "$TMP"
mv -f "$TMP" "$OUTDIR/app_metrics.prom"
