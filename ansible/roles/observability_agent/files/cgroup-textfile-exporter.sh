#!/usr/bin/env bash
# Le cgroup v2 de cada dotnet-app@X e escreve no formato textfile que o
# node_exporter_metrics embutido do Fluent Bit ja consome.
#
# Existe porque o collector `processes` so conta processos por estado: nao da
# CPU nem memoria individual. Como cada app roda com MemoryMax e CPUQuota
# proprios, sem isto o throttling e o OOM por app ficam invisiveis.

set -uo pipefail

CGROOT=/sys/fs/cgroup/apps.slice
OUTDIR=/var/lib/node_exporter/textfile
TMP=$(mktemp "$OUTDIR/.app_metrics.XXXXXX")

kv() { awk -v k="$2" '$1==k{print $2; exit}' "$1" 2>/dev/null; }

{
  echo "# HELP app_mem_bytes Memoria atual do cgroup do app"
  echo "# TYPE app_mem_bytes gauge"
  echo "# HELP app_mem_max_bytes Teto duro de memoria do cgroup"
  echo "# TYPE app_mem_max_bytes gauge"
  echo "# HELP app_mem_pct Percentual do memory.max em uso"
  echo "# TYPE app_mem_pct gauge"
  echo "# HELP app_cpu_pct Uso de CPU no ultimo intervalo (100 = 1 core)"
  echo "# TYPE app_cpu_pct gauge"
  echo "# HELP app_cpu_throttled_pct Percentual do tempo barrado pela CPUQuota"
  echo "# TYPE app_cpu_throttled_pct gauge"
  echo "# HELP app_cpu_throttled_periods_total Periodos em que a CPUQuota barrou o app"
  echo "# TYPE app_cpu_throttled_periods_total counter"
  echo "# HELP app_oom_kills_total Processos mortos pelo OOM killer dentro do cgroup"
  echo "# TYPE app_oom_kills_total counter"
  echo "# HELP app_mem_events_high_total Vezes que o cgroup ultrapassou MemoryHigh"
  echo "# TYPE app_mem_events_high_total counter"

  for cg in "$CGROOT"/dotnet-app@*.service; do
    [ -d "$cg" ] || continue
    unit=$(basename "$cg"); app=${unit#dotnet-app@}; app=${app%.service}
    lbl="app=\"${app}\""

    mem_cur=$(cat "$cg/memory.current" 2>/dev/null || echo 0)
    mem_max=$(cat "$cg/memory.max" 2>/dev/null || echo max)

    # memory.events: `oom_kill` e o contador que prova que houve OOM DENTRO do
    # limite do app -- diferente do OOM do host, que aparece no journal.
    oom_kill=$(kv "$cg/memory.events" oom_kill); oom_kill=${oom_kill:-0}
    mem_high=$(kv "$cg/memory.events" high); mem_high=${mem_high:-0}

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
    printf 'prev_usage=%s\nprev_ts=%s\nprev_thr_usec=%s\n' "$usage_usec" "$now" "$throttled_usec" > "$sf"

    if [ "$mem_max" = "max" ]; then
      mem_pct=0; mem_max_out=0
    else
      mem_max_out=$mem_max
      mem_pct=$(awk -v c="$mem_cur" -v m="$mem_max" 'BEGIN{ if (m>0) printf "%.1f", c/m*100; else printf "0" }')
    fi

    echo "app_mem_bytes{${lbl}} ${mem_cur}"
    echo "app_mem_max_bytes{${lbl}} ${mem_max_out}"
    echo "app_mem_pct{${lbl}} ${mem_pct}"
    echo "app_cpu_pct{${lbl}} ${cpu_pct}"
    echo "app_cpu_throttled_pct{${lbl}} ${thr_pct}"
    echo "app_cpu_throttled_periods_total{${lbl}} ${nr_throttled}"
    echo "app_oom_kills_total{${lbl}} ${oom_kill}"
    echo "app_mem_events_high_total{${lbl}} ${mem_high}"
  done
} > "$TMP"

chmod 644 "$TMP"
mv -f "$TMP" "$OUTDIR/app_metrics.prom"
