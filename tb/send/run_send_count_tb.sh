#!/bin/sh
# Build and run the SEND count test at three clock ratios.
# Usage: CDC_JITTER=0|1 sh run_send_count_tb.sh [build_dir [seed ...]]
set -eu

send_script=$(readlink -f "$0")
send_here=$(dirname "$send_script")
send_ctrl=$(dirname "$(dirname "$send_here")")
send_work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/tj_send_count.XXXXXX")}
if [ "$#" -gt 0 ]; then shift; fi
if [ "$#" -eq 0 ]; then set -- 1 2 3 4; fi
mkdir -p "$send_work"
send_work=$(readlink -f "$send_work")

send_cdc="$send_ctrl/rtl/common/tj_cdc.sv"
if [ "${CDC_JITTER:-0}" = 1 ]; then
  send_cdc="$send_ctrl/tb/common/tj_cdc_jit.sv"
fi

cd "$send_work"
vlogan -full64 -sverilog -nc -timescale=1ns/1ps \
  "$send_ctrl/rtl/pkg/tj_ctrl_pkg.sv" "$send_cdc" \
  "$send_ctrl/rtl/dma/tj_send_fetch.sv" \
  "$send_ctrl/rtl/dma/tj_send_engine.sv" \
  "$send_ctrl/rtl/dma/tj_send_subsys.sv" \
  "$send_here/tb_tj_send_count.sv" > compile.log 2>&1
vcs -full64 -nc tb_tj_send_count -o simv > elaborate.log 2>&1

for send_ratio in default delivery boundary; do
  case "$send_ratio" in
    default)  send_p=5.0;  send_m=1.2 ;;
    delivery) send_p=2.0;  send_m=10.0 ;;
    boundary) send_p=50.0; send_m=5.0 ;;
  esac
  for send_seed in "$@"; do
    send_log="${send_ratio}_${send_seed}.log"
    if ./simv -nc "+TJ_PCLK_HP=$send_p" "+TJ_MAXI_HP=$send_m" \
      "+ntb_random_seed=$send_seed" > "$send_log" 2>&1; then
      if ! grep -Eq '^SEND COUNT TB PASS \([1-9][0-9]* checks\)$' "$send_log"; then
        cat "$send_log"
        exit 1
      fi
    else
      send_status=$?
      cat "$send_log"
      exit "$send_status"
    fi
    printf '%s: ' "$send_log"
    grep '^SEND COUNT TB PASS' "$send_log"
  done
done
