#!/bin/sh
# Run the default die-level cases sequentially, followed by any extra cases.
# Usage: sh controller/scripts/run_chip_sim_batch.sh [extra_case ...]
# Case names are relative to ROOT below.
# MD=1 appends the small and full multi-die cases; full cases can take several hours.
# Each batch keeps separate logs under TMPDIR (default: /tmp).
set -u
ROOT=/data_8T_2/Tianjic/all_cases
HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
# Run all cases with the same two scripts.
if [ ! -f "$HERE/.tj_batch_entry_repo" ]; then
  LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tj_chip_sim_batch.XXXXXX") || exit 1
  cp "$HERE/run_chip_sim_batch.sh" "$HERE/run_chip_sim.sh" "$LOG_DIR/" || exit 1
  dirname "$(dirname "$HERE")" > "$LOG_DIR/.tj_batch_entry_repo" || exit 1
  exec sh "$LOG_DIR/run_chip_sim_batch.sh" "$@"
fi
LOG_DIR=$HERE
printf '== Chip simulation logs: %s\n' "$LOG_DIR"

CASES="
die_extern/resnet9_lvds
core_array/ann_sparse
core_array/spiketrans_multi_core
core_array/conv_split_6cores
core_array/resnet9_2cores
core_array/multihead_attention_3cores_one2many
core_array/hybrid_ann_snn
core_array/branch_eq
core_array/loop_lif_9_2_2
die/16_core_resnet9
die/16_core_spiketrans
"
[ "${MD:-0}" = "1" ] && CASES="$CASES
multi_die/conv_split_lvds_2dies_small
multi_die/conv_split_spi_lvds_2dies_small
multi_die/conv_split_lvds_2dies
multi_die/conv_split_lvds_4dies
"
[ $# -gt 0 ] && CASES="$CASES $*"

PASS=0
FAILED=0
FAIL_LIST=""
for c in $CASES; do
  CASE_LOG="$LOG_DIR/$((PASS + FAILED + 1))_$(printf '%s' "$c" | tr / _).log"
  printf '== Chip simulation case: %s\n' "$c"
  SPECIALS=0
  # Add dx=-32 and link-error checks for die_extern cases.
  case "$c" in die_extern/*) SPECIALS=1;; esac
  # Full multi-die cases currently use the no-sleep configuration.
  EXTRA_ARGS=${TJ_EXTRA:-}
  case "$c" in
    multi_die/conv_split_lvds_2dies|multi_die/conv_split_lvds_4dies)
      EXTRA_ARGS="$EXTRA_ARGS +TJ_NOSLEEP"
      ;;
  esac
  if LVDS_EXTRA_TESTS=$SPECIALS TJ_EXTRA="$EXTRA_ARGS" sh "$HERE/run_chip_sim.sh" "$ROOT/$c" > "$CASE_LOG" 2>&1; then
    PASS=$((PASS+1))
    printf '   PASS  %s\n' "$(grep 'CTRL CHIP TB PASS' "$CASE_LOG" | tail -1)"
  else
    FAILED=$((FAILED+1))
    FAIL_LIST="$FAIL_LIST $c"
    printf '   FAIL (log: %s)\n' "$CASE_LOG"
  fi
done

echo
printf '== Chip simulation summary:PASS=%d FAIL=%d%s\n' "$PASS" "$FAILED" "${FAIL_LIST:+ 失败:$FAIL_LIST}"
[ $FAILED -eq 0 ]
