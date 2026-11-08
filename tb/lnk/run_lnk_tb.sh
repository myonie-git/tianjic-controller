#!/bin/sh
# Build and run LVDS packet and configuration-chain tests.
# Usage: sh run_lnk_tb.sh [build_dir [seed ...]]
# LNK_TESTS selects lnk/cfgchain; LNK_CASES and CFGCHAIN_CASES select scenes.
set -eu
LNK_TESTS=${LNK_TESTS:-"lnk cfgchain"}
for lnk_test in $LNK_TESTS; do
  case "$lnk_test" in
    lnk|cfgchain) ;;
    *) printf 'Unknown LNK_TESTS module: %s\n' "$lnk_test" >&2; exit 2 ;;
  esac
done
lnk_selected() {
  case " $LNK_TESTS " in *" $1 "*) return 0 ;; esac
  return 1
}

lnk_script=$(readlink -f "$0")
lnk_here=$(dirname "$lnk_script")
lnk_ctrl=$(dirname "$(dirname "$lnk_here")")
lnk_repo=$(dirname "$lnk_ctrl")
lnk_work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/tj_lnk.XXXXXX")}
if [ "$#" -gt 0 ]; then shift; fi
if [ "$#" -eq 0 ]; then set -- 1 31 166; fi
mkdir -p "$lnk_work"
lnk_work=$(readlink -f "$lnk_work")

YAWING_DESIGN=${YAWING_DESIGN:-"$lnk_repo/soc/design"}
YAWING_DESIGN=$(cd "$YAWING_DESIGN" && pwd)
if [ -z "${DW_SIM_DIR:-}" ]; then
  lnk_dc=$(command -v dc_shell || true)
  if [ -z "$lnk_dc" ]; then
    printf '%s\n' 'Set DW_SIM_DIR to the directory containing DW_ecc.v.' >&2
    exit 2
  fi
  DW_SIM_DIR=$(dirname "$(dirname "$lnk_dc")")/dw/sim_ver
fi
if [ ! -r "$DW_SIM_DIR/DW_ecc.v" ]; then
  printf 'DW_ecc.v not found in %s\n' "$DW_SIM_DIR" >&2
  exit 2
fi
DW_SIM_DIR=$(cd "$DW_SIM_DIR" && pwd)
export YAWING_DESIGN DW_SIM_DIR

# Preserve the simulator exit status before checking its final PASS summary.
run_checked() {
  lnk_log=$1
  lnk_tag=$2
  shift 2
  if "$@" > "$lnk_log" 2>&1; then
    if grep -Eq "^${lnk_tag} TB PASS \([1-9][0-9]* checks\)$" "$lnk_log"; then
      printf '%s: ' "$(basename "$lnk_log")"
      grep -E "^${lnk_tag} TB PASS \([1-9][0-9]* checks\)$" "$lnk_log"
    else
      cat "$lnk_log"
      return 1
    fi
  else
    lnk_status=$?
    cat "$lnk_log"
    return "$lnk_status"
  fi
}

printf 'Build directory: %s\n' "$lnk_work"
cd "$lnk_work"
vlogan -full64 -sverilog "+incdir+$lnk_ctrl/tb/common" -timescale=1ps/1fs +error+5000 \
  +define+FOR_SIM_ONLY +define+RTL -f "$lnk_here/lvds_files.f" > vlogan_chip.log 2>&1
vlogan -full64 -sverilog "+incdir+$lnk_ctrl/tb/common" -timescale=1ps/1fs +error+5000 \
  +define+FOR_SIM_ONLY +define+RTL \
  "$lnk_ctrl/rtl/pkg/tj_ctrl_pkg.sv" \
  "$lnk_ctrl/rtl/pkg/tj_ctrl_if.sv" \
  "$lnk_ctrl/rtl/csr/tj_ctrl_csr_pkg.sv" \
  "$lnk_ctrl/rtl/csr/tj_ctrl_csr.sv" \
  "$lnk_ctrl/rtl/lnk/tj_cfgchain_master.sv" \
  "$lnk_ctrl/rtl/lnk/tj_lnk_plugs.sv" \
  "$lnk_here/tb_tj_lnk.sv" \
  "$lnk_here/tb_tj_cfgchain.sv" > vlogan_tb.log 2>&1
if lnk_selected lnk; then
    vcs -full64 -top tb_tj_lnk -o simv_lnk > vcs_lnk.log 2>&1
  fi
  if lnk_selected cfgchain; then
    vcs -full64 -top tb_tj_cfgchain -o simv_cfgchain > vcs_cfgchain.log 2>&1
  fi

  if lnk_selected lnk; then
  for lnk_mode in 211f 210f; do
    for lnk_seed in "$@"; do
      if [ "$lnk_mode" = 210f ]; then
        run_checked "lnk_${lnk_mode}_${lnk_seed}.log" LNK \
          ./simv_lnk -nc ${LNK_CASES:+"+TJ_CASES=$LNK_CASES"} "+ntb_random_seed=$lnk_seed" +GRP210F
      else
        run_checked "lnk_${lnk_mode}_${lnk_seed}.log" LNK \
          ./simv_lnk -nc ${LNK_CASES:+"+TJ_CASES=$LNK_CASES"} "+ntb_random_seed=$lnk_seed"
      fi
    done
  done
else
  printf "%s\n" "SKIP lnk (not selected)"
fi
if lnk_selected cfgchain; then
  run_checked cfgchain_100mhz.log CFGCHAIN ./simv_cfgchain -nc ${CFGCHAIN_CASES:+"+TJ_CASES=$CFGCHAIN_CASES"} +TJ_PCLK_HP=5.0
  run_checked cfgchain_250mhz.log CFGCHAIN ./simv_cfgchain -nc ${CFGCHAIN_CASES:+"+TJ_CASES=$CFGCHAIN_CASES"} +TJ_PCLK_HP=2.0
else
  printf "%s\n" "SKIP cfgchain (not selected)"
fi
