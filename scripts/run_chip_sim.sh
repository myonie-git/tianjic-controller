#!/bin/sh
# Run one Controller case in the native single-die simulation.
# Usage: JOBNAME=<name> sh controller/scripts/run_chip_sim.sh [case_dir]
# TJ_REPO selects the chip environment; TJ_CTRL_HOME selects Controller sources and tools.
# Jobs default to tjctrl_<pid>; use different JOBNAME values for concurrent runs.
# Cases with lvds_config.txt use LVDS; others use SPI and backdoor memory loading.
# LVDS_EXTRA_TESTS=1 enables dx=-32 and link-error tests in LVDS mode.
set -u
CASE=${1:-/data_8T_2/Tianjic/all_cases/core_array/ann_sparse}
CASE=$(cd "$CASE" && pwd) || exit 1
HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
ENTRY_REPO=$(dirname "$(dirname "$HERE")")
REPO=${TJ_REPO:-$ENTRY_REPO}
REPO=$(cd "$REPO" && pwd) || exit 1
TJ_CTRL_HOME=$(cd "${TJ_CTRL_HOME:-$ENTRY_REPO/controller}" && pwd) || exit 1
export TJ_CTRL_HOME
JOB=${JOBNAME:-tjctrl_$$}
WORK=/data_8T_2/Tianjic/work/proj/yawing/temp/$(id -un)
RUN=$WORK/tjctrl_run_$(basename "$CASE")__$JOB
BUILD=full_chip_tianjic_tjctrl
BUILD_CFG=$ENTRY_REPO/soc/verif/build/$BUILD.build

# Native chip simulation environment.
export PATH="$REPO:$PATH"
export TIANJIC_A_HOME=$REPO
export TIANJIC_A_DESIGN=$REPO/design
export DESIGN_ROOT=$REPO/soc/verif YAWING_ROOT=$REPO/soc/verif
export YAWING_HOME=$REPO/soc YAWING_DESIGN=$REPO/soc/design
export ISIM_HOME=$REPO/soc/utilities/isim ISIM_HOME_LOCAL=$REPO/soc/utilities/isim
export SNPS_VIP=/projects/yicheng/vip/T-2022.09 DESIGNWARE_HOME=/projects/yicheng/vip
export XT900_CC=/projects/yicheng/xt900
export PYTHONIOENCODING=utf-8

# Generate inputs with the tool from the selected Controller tree.
mkdir -p "$RUN" || exit 1
python3 "$TJ_CTRL_HOME/sw/tj_image.py" export "$CASE" -o "$RUN/image" || exit 1

# Use this script's build configuration with the selected chip environment.
( cd "$REPO/soc/verif/full_chip_subsys/sim" && \
  make -f "$REPO/soc/utilities/isim/isim.vcs.mk" PROJ=yawing co \
    BUILD="$BUILD" BUILD_FILE="$BUILD_CFG" JOBNAME="$JOB" WORK_DIR="$WORK" LSF=Y ) || exit 1

B=$WORK/$BUILD/$JOB/build
ln -sfn "$B/simv" "$RUN/simv" || exit 1
ln -sfn "$B/simv.daidir" "$RUN/simv.daidir" || exit 1
ln -sfn "$B/full_chip_subsys" "$RUN/full_chip_subsys" || exit 1

# Reused job directories must not retain a previous PASS log.
rm -f "$RUN/dielevel.log" || exit 1
cd "$RUN" || exit 1
SPECIAL_ARGS=""
[ "${LVDS_EXTRA_TESTS:-0}" = "1" ] && SPECIAL_ARGS="+TJ_ECCTEST +TJ_DXTEST"
if [ -f "$CASE/lvds_config.txt" ]; then
  # LVDS output is compared as a complete packet stream.
  NOUT=$(grep -c '^@' "$CASE/lvds_golden.txt") || exit 1
  ./simv -licqueue +UVM_VERBOSITY=UVM_LOW +UVM_TESTNAME=soc_base_test \
    +UVM_MAX_QUIT_COUNT=10000 -l dielevel.log +use_tj_ctrl +TJ_LVDS \
    +TJ_PY="$TJ_CTRL_HOME/sw/tj_image.py" \
    +TJ_CASE="$CASE" \
    +TJ_IMG=image/send_image.bin \
    +TJ_REGS=image/init_regs.txt \
    +TJ_GOLDEN="$CASE/lvds_golden.txt" \
    +TJ_NOUT="$NOUT" $SPECIAL_ARGS \
    +TJ_OUT=lvds_outputs.txt +ntb_random_seed=888
  SIM_RC=$?
else
  # SPI control with per-core memory comparison.
  ./simv -licqueue +UVM_VERBOSITY=UVM_LOW +UVM_TESTNAME=soc_base_test \
    +UVM_MAX_QUIT_COUNT=10000 -l dielevel.log +use_tj_ctrl \
    +TJ_PY="$TJ_CTRL_HOME/sw/tj_image.py" \
    +TJ_CASE="$CASE" \
    +TJ_REGS=image/init_regs.txt +ntb_random_seed=888
  SIM_RC=$?
fi

# Require successful execution and a PASS from this run, with no failure messages.
if [ "$SIM_RC" -ne 0 ]; then
  echo "** FAIL: simv exited with status $SIM_RC (log: $RUN/dielevel.log)"
  exit 1
fi
if [ ! -s "$RUN/dielevel.log" ]; then
  echo "** FAIL: this run did not produce dielevel.log"
  exit 1
fi
grep -E "CTRL CHIP TB (PASS|FAIL|TIMEOUT)|golden|泛洪|专项" "$RUN/dielevel.log" | tail -8
if ! awk '
  /CTRL CHIP TB (FAIL|TIMEOUT)/ { failed = 1 }
  /^[[:space:]]*(Fatal:|FATAL|Error-\[)/ { failed = 1 }
  /^[[:space:]]*UVM_(ERROR|FATAL)[[:space:]]*:/ {
    sub(/^[^:]*:[[:space:]]*/, "")
    if ($1 + 0 > 0) failed = 1
    next
  }
  /^[[:space:]]*UVM_(ERROR|FATAL)[[:space:]]/ { failed = 1 }
  END { exit failed ? 1 : 0 }
' "$RUN/dielevel.log"; then
  echo "** FAIL: simulation reported errors (log: $RUN/dielevel.log)"
  exit 1
fi
if ! grep -Eq '^CTRL CHIP TB PASS \([1-9][0-9]* checks\)' "$RUN/dielevel.log"; then
  echo "** FAIL: missing CTRL CHIP TB PASS with nonzero checks (log: $RUN/dielevel.log)"
  exit 1
fi
