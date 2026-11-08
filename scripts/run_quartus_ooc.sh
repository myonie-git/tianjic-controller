#!/bin/sh
# Run an out-of-context (OOC) build of tj_ctrl_top with virtual pins and report CDC timing paths.
# Usage: sh run_quartus_ooc.sh [project_dir]
# FAM and DEV select the device. PCLK_NS and MAXI_NS are periods in ns.
# The default is a new directory under /data_8T_2/$USER/work/quartus-ooc.
set -u
FAM=${FAM:-"Cyclone 10 GX"}
DEV=${DEV:-10CX220YF672E5G}
PCLK_NS=${PCLK_NS:-4.0}
MAXI_NS=${MAXI_NS:-10.0}
HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
TJ=$(dirname "$HERE")

command -v quartus_syn >/dev/null 2>&1 || { echo "quartus_syn is not in PATH" >&2; exit 1; }
if [ -n "${1:-}" ]; then
  mkdir -p -- "$1" || exit 1
  W=$(CDPATH= cd -- "$1" && pwd) || exit 1
  first_entry=$(find "$W" -mindepth 1 -maxdepth 1 -print -quit) || exit 1
  if [ -n "$first_entry" ]; then
    printf 'Project directory is not empty: %s\n' "$W" >&2
    exit 1
  fi
else
  work_root="/data_8T_2/${USER:-$(id -un)}/work/quartus-ooc"
  mkdir -p -- "$work_root" || exit 1
  W=$(mktemp -d "$work_root/tjctrl-XXXXXX") || exit 1
fi
printf 'Project directory: %s\n' "$W"

( set -C
  sed -e '/^[[:space:]]*\/\//d' -e '/^[[:space:]]*$/d' -e "s|\${TJ_CTRL_HOME}|$TJ|" \
    "$TJ/flist/tj_ctrl.f" > "$W/files.lst"
) || exit 1

{
  printf 'set_global_assignment -name FAMILY "%s"\n' "$FAM"
  printf 'set_global_assignment -name DEVICE %s\n' "$DEV"
  echo 'set_global_assignment -name TOP_LEVEL_ENTITY tj_ctrl_top'
  echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 16'
  while IFS= read -r f; do printf 'set_global_assignment -name SYSTEMVERILOG_FILE {%s}\n' "$f"; done < "$W/files.lst"
  echo 'set_global_assignment -name SDC_FILE tjctrl_ooc.sdc'
  echo 'set_instance_assignment -name VIRTUAL_PIN ON -to *'
} > "$W/tjctrl.qsf" || exit 1

write_sdc() {
  printf 'create_clock -name pclk -period %s [get_ports pclk]\n' "$PCLK_NS"
  printf 'create_clock -name maxi_clk -period %s [get_ports maxi_clk]\n' "$MAXI_NS"
  echo 'derive_clock_uncertainty'
  for var in TJ_BOOT_PCLK_PERIOD TJ_SEND_PCLK_PERIOD TJ_TS_PCLK_PERIOD TJ_RECV_PCLK_PERIOD; do
    printf 'set %s %s\n' "$var" "$PCLK_NS"
  done
  for var in TJ_RECV_MAXI_PERIOD TJ_BOOT_MAXI_PERIOD; do
    printf 'set %s %s\n' "$var" "$MAXI_NS"
  done
  # Add routing margin for BOOT addresses and RECV read pointers during fitting.
  if [ "$1" = fit ] && [ "$DEV" = 10CX220YF672E5G ]; then
    echo 'set TJ_BOOT_MAXI_PERIOD [expr {min($TJ_BOOT_MAXI_PERIOD, 2.4)}]'
    echo 'set TJ_BOOT_FIT_HOLD_MARGIN 0.30'
    echo 'set TJ_RECV_RPTR_FIT_HOLD_MARGIN 0.30'
  fi
  for group in ctrl send_snapshot ts_snapshot recv_wptr_snapshot recv_rptr_snapshot boot_fetch_addr; do
    printf 'source {%s/scripts/tj_%s_quartus.sdc}\n' "$TJ" "$group"
  done
}
write_sdc fit > "$W/tjctrl_fit.sdc" || exit 1
write_sdc signoff > "$W/tjctrl_signoff.sdc" || exit 1
cp "$W/tjctrl_fit.sdc" "$W/tjctrl_ooc.sdc" || exit 1

cat > "$W/audit.tcl" <<'TCL'
project_open tjctrl
create_timing_netlist
read_sdc
update_timing_netlist

proc show_paths {tag paths} {
    set n 0
    foreach_in_collection path $paths {
        incr n
        set src [get_node_info [get_path_info $path -from] -name]
        set dst [get_node_info [get_path_info $path -to] -name]
        puts [format "PATH %s %.3f %s -> %s" $tag [get_path_info $path -slack] $src $dst]
    }
    if {$n == 0} {error "NO PATH: $tag"}
}
foreach {tag src dst} {
    SENT      {*u_sent_syn|snap_q*}               {*u_sent_syn|q*}
    TS        {*u_ts_rd_syn|snap_q*}              {*u_ts_rd_syn|q*}
    WPTR      {*u_wp|snap_q*}                     {*u_wp|q*}
    RPTR      {*u_rptr|snap_q*}                   {*u_rptr|q*}
    BOOT_BLK  {*u_boot*|*u_fetch*|blk*}           {*u_boot*|*u_engine*|*}
    BOOT_ADDR {*u_boot*|*u_engine*|f_blk_addr*}  {*u_boot*|*u_fetch*|addr_q*}
} {
    show_paths $tag [get_timing_paths -setup -from [get_registers $src] -to [get_registers $dst] -npaths 2]
}
foreach inst {u_src_syn u_cnt_syn u_en_syn u_rm0_syn u_rm1_syn} {
    show_paths $inst [get_timing_paths -data_delay -from_clock [get_clocks pclk] \
        -to [get_registers "*u_send*|*${inst}*|meta_q*"] -npaths 2]
}
foreach inst {u_base u_size u_wmk u_en u_pol u_remap0} {
    show_paths "RECV/$inst" [get_timing_paths -data_delay -from_clock [get_clocks pclk] \
        -to [get_registers "*u_recv*|*${inst}*|meta_q*"] -npaths 2]
}
delete_timing_netlist
project_close
TCL

cd "$W" || exit 1
echo "== Synthesis"
quartus_syn tjctrl > syn.log 2>&1 || { tail -20 syn.log; exit 1; }
echo "== Fitter"
quartus_fit tjctrl > fit.log 2>&1 || { tail -20 fit.log; exit 1; }
cp tjctrl_signoff.sdc tjctrl_ooc.sdc || exit 1
echo "== Timing Analyzer"
quartus_sta tjctrl > sta.log 2>&1 || { tail -20 sta.log; exit 1; }
echo "== CDC paths"
quartus_sta -t audit.tcl > audit.log 2>&1 || {
  rc=$?
  tail -n 20 audit.log >&2
  exit "$rc"
}
grep '^PATH ' audit.log

echo "== Resources"
grep -E "Logic utilization \(in ALMs\)|Total registers|Total RAM Blocks" tjctrl.fit.summary
echo "== Timing"
awk '/^Type[[:space:]]*:[[:space:]]*(Setup|Hold)[[:space:]]/ { print; if (getline > 0) print }' tjctrl.sta.summary || exit 1
echo "Reports: $W"
