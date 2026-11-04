#!/bin/sh
# Run Controller regression tests and lint checks.
# Usage: sh controller/scripts/run_regress.sh
# Requires Python 3 and VCS in PATH; SpyGlass is optional.
# REGRESS_WORK selects the output directory, which is cleared before each run.
# INIT_CASE selects the single-die initialization replay case.
# SEEDS overrides SPI seeds; EXTRA_SEEDS appends more.
# SKIP_APB_SMOKE, SKIP_SG and SKIP_LNK skip the corresponding stages.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
export TJ_CTRL_HOME=$(dirname "$SCRIPT_DIR")
REPO=$(dirname "$TJ_CTRL_HOME")
export YAWING_DESIGN=${YAWING_DESIGN:-$REPO/soc/design}
export TIANJIC_A_DESIGN=${TIANJIC_A_DESIGN:-$REPO/design}
WORK=${REGRESS_WORK:-/tmp/tj_regress_$(id -un)}
SEEDS=${SEEDS:-"default 31 166 336 7 99"}${EXTRA_SEEDS:+" $EXTRA_SEEDS"}
FAIL=0

say()  { printf '%s\n' "== $*"; }
bad()  { printf '%s\n' "** FAIL: $*"; FAIL=1; }

# A PASS line must have real checks and no accompanying failure diagnostics.
log_clean() {
  ! grep -Eq '(^|[[:space:]])(FAIL|TIMEOUT)([[:space:]:]|$)|^[[:space:]]*(Fatal:|Error[-:])' "$1"
}
sim_passed() {
  grep -Eq "^$2 PASS \\([1-9][0-9]* checks\\)$" "$1" && log_clean "$1"
}

rm -rf "$WORK"; mkdir -p "$WORK/gen" "$WORK/csr" "$WORK/spi" "$WORK/top" "$WORK/apb_smoke" "$WORK/sg"

# CSR generated files.
say "[1/12] 生成物防漂移门禁"
mkdir -p "$WORK/gen/rtl" "$WORK/gen/doc" "$WORK/gen/tb"
( cd "$TJ_CTRL_HOME/csr" && python3 gen_csr.py tj_ctrl_csr.yaml \
    --out-rtl "$WORK/gen/rtl" --out-doc "$WORK/gen/doc" --out-tb "$WORK/gen/tb" ) \
  > "$WORK/gen/gen.log" 2>&1 || bad "生成器执行失败(见 $WORK/gen/gen.log)"
for pair in \
  "rtl/tj_ctrl_csr_pkg.sv:$TJ_CTRL_HOME/rtl/csr/tj_ctrl_csr_pkg.sv" \
  "rtl/tj_ctrl_csr.sv:$TJ_CTRL_HOME/rtl/csr/tj_ctrl_csr.sv" \
  "tb/tb_tj_ctrl_csr.sv:$TJ_CTRL_HOME/tb/csr/tb_tj_ctrl_csr.sv" \
  "doc/tj_ctrl_regmap.md:$TJ_CTRL_HOME/doc/tj_ctrl_regmap.md" ; do
  new="$WORK/gen/${pair%%:*}"; old="${pair#*:}"
  cmp -s "$new" "$old" || bad "生成物漂移:$old 与真源再生成不一致(忘了 regen.sh?)"
done
[ $FAIL -eq 0 ] && say "    门禁通过:四件产物与真源逐字节一致"

# CSR register test.
say "[2/12] CSR 自测 TB"
if ( cd "$WORK/csr" && \
  vlogan -full64 -sverilog -nc -timescale=1ns/1ps \
    "$TJ_CTRL_HOME/rtl/csr/tj_ctrl_csr_pkg.sv" \
    "$TJ_CTRL_HOME/rtl/csr/tj_ctrl_csr.sv" \
    "$TJ_CTRL_HOME/tb/csr/tb_tj_ctrl_csr.sv" && \
  vcs -full64 -nc tb_tj_ctrl_csr -o simv && ./simv -nc ) \
  > "$WORK/csr/run.log" 2>&1 && \
  sim_passed "$WORK/csr/run.log" "CSR TB"; then
  say "    $(grep 'CSR TB PASS' "$WORK/csr/run.log")"
else
  bad "CSR TB 未 PASS(见 $WORK/csr/run.log)"
fi

# SPI tests across seeds.
say "[3/12] SPI 陪练 TB × 种子集 [$SEEDS]"
( cd "$WORK/spi" && \
  vlogan -full64 -sverilog -nc -timescale=1ns/1ps \
    "$TJ_CTRL_HOME/rtl/pkg/tj_ctrl_pkg.sv" \
    "$TJ_CTRL_HOME/rtl/csr/tj_ctrl_csr_pkg.sv" \
    "$TJ_CTRL_HOME/rtl/spi/tj_spi_engine.sv" \
    "$TJ_CTRL_HOME/rtl/spi/tj_spi_subsys.sv" \
    "$YAWING_DESIGN/rtl/mcu_subsys/spi/spi2ahb.v" \
    "$TJ_CTRL_HOME/tb/spi/tb_tj_spi.sv" && \
  vcs -full64 -nc tb_tj_spi -o simv ) > "$WORK/spi/build.log" 2>&1 \
  || bad "SPI TB 构建失败(见 $WORK/spi/build.log)"
n_pass=0
for s in $SEEDS; do
  arg=""; [ "$s" != "default" ] && arg="+ntb_random_seed=$s"
  if ( cd "$WORK/spi" && ./simv -nc $arg ) > "$WORK/spi/run_$s.log" 2>&1 && \
    sim_passed "$WORK/spi/run_$s.log" "SPI TB"; then
    n_pass=$((n_pass+1))
  else
    bad "SPI TB seed=$s 未 PASS(见 $WORK/spi/run_$s.log)"
  fi
done
n_seed=$(echo $SEEDS | wc -w)
[ "$n_pass" = "$n_seed" ] && say "    全种子($n_pass/$n_seed) $(grep -h 'SPI TB PASS' "$WORK"/spi/run_*.log | sort -u)"

# Top-level elaboration.
say "[4/12] 顶层弹性"
( cd "$WORK/top" && \
  vlogan -full64 -sverilog -nc -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" && \
  vcs -full64 -nc tj_ctrl_top -o simv ) > "$WORK/top/run.log" 2>&1 \
  && log_clean "$WORK/top/run.log" && say "    TOP ELAB OK" || bad "顶层弹性失败(见 $WORK/top/run.log)"

# Compile Controller and chip RTL together, then run the APB smoke test.
if [ "${SKIP_APB_SMOKE:-0}" = "1" ]; then
  say "[5/12] APB 共库冒烟:SKIP_APB_SMOKE=1 跳过"
else
  say "[5/12] APB 共库编译及APB冒烟"
  # Match the native chip build's duplicate-module policy.
  if ( cd "$WORK/apb_smoke" && \
    vlogan -full64 -sverilog -nc -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" && \
    vlogan -full64 -sverilog -nc -timescale=1ns/1ps +error+5000 -error=noMPD \
      -f "$YAWING_DESIGN/flist/chip_top_tianjic.sim.f" && \
    vlogan -full64 -sverilog -nc -timescale=1ns/1ps "$TJ_CTRL_HOME/tb/top/tb_tj_ctrl_apb_smoke.sv" && \
    vcs -full64 -nc tb_tj_ctrl_apb_smoke -o simv && ./simv -nc ) > "$WORK/apb_smoke/run.log" 2>&1 && \
    sim_passed "$WORK/apb_smoke/run.log" "CTRL APB SMOKE TB"; then
    say "    CTRL APB SMOKE TB PASS"
  else
    bad "APB 冒烟编译或仿真失败(见 $WORK/apb_smoke/run.log)"
  fi
fi

# SpyGlass lint.
if [ "${SKIP_SG:-0}" = "1" ] || ! command -v spyglass >/dev/null 2>&1; then
  say "[6/12] SpyGlass lint:跳过(SKIP_SG=1 或未装)"
else
  say "[6/12] SpyGlass lint(goal lint/lint_rtl)"
  sed "s|\${TJ_CTRL_HOME}|$TJ_CTRL_HOME|g" "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
    > "$WORK/sg/expanded.f"
  cat > "$WORK/sg/tj.prj" <<EOF
#!SPYGLASS_PROJECT_FILE
#!VERSION 3.0
set_option projectwdir $WORK/sg
set_option language_mode mixed
# Allow synthesis of the 32768-bit SEND buffer.
set_option mthresh 131072
set_option enableSV09 yes
set_option top tj_ctrl_top
read_file -type sourcelist $WORK/sg/expanded.f
EOF
  if ! ( cd "$WORK/sg" && spyglass -project tj.prj -goal lint/lint_rtl -batch ) \
    > "$WORK/sg/run.log" 2>&1; then
    bad "SpyGlass 执行失败(见 $WORK/sg/run.log)"
  else
    RPT=$(find "$WORK/sg" -name moresimple.rpt 2>/dev/null | head -1)
    # Severity is field 3 without an alias, otherwise field 4.
    if [ ! -s "$RPT" ]; then
      bad "SpyGlass 未产出有效报告(见 $WORK/sg/run.log)"
    elif ! NERR=$(awk '
      /^[[:space:]]*\[/ {
        for (i = 3; i <= 4 && i <= NF; i++) {
          severity = tolower($i)
          if (severity == "error" || severity == "fatal" ||
              severity == "synthesiserror" || severity == "syntaxerror") {
            n++
            break
          }
        }
      }
      END { print n + 0 }
    ' "$RPT"); then
      bad "SpyGlass 报告读取失败(报告:$RPT)"
    elif [ "$NERR" -gt 0 ]; then
      bad "SpyGlass 报 $NERR 个 Error(报告:$RPT)"
    else
      say "    SpyGlass lint 零 Error(告警见 $RPT)"
    fi
  fi
fi

# Image exporter CLI and SV format checks.
say "[7/12] 镜像工具与格式检查"
mkdir -p "$WORK/image"
if PYTHONIOENCODING=utf-8 python3 "$TJ_CTRL_HOME/tb/sw/test_tj_image.py" \
  --tool "$TJ_CTRL_HOME/sw/tj_image.py" --work "$WORK/image/python" \
  > "$WORK/image/python.log" 2>&1; then
  say "    镜像工具测试通过(见 $WORK/image/python.log)"
else
  bad "镜像工具测试失败(见 $WORK/image/python.log)"
fi
IMAGE_CASE=${IMAGE_CASE:-/data_8T_2/Tianjic/all_cases/multi_die/conv_split_lvds_2dies}
if [ ! -d "$IMAGE_CASE" ]; then
  say "    SV格式检查:测例目录不可达,跳过($IMAGE_CASE)"
else
  if ( IMAGE_CASE=$(cd "$IMAGE_CASE" && pwd) && \
    python3 "$TJ_CTRL_HOME/sw/tj_image.py" export "$IMAGE_CASE" -o "$WORK/image/out" && \
    cd "$WORK/image" && \
    vlogan -full64 -sverilog -nc -timescale=1ns/1ps \
      "$TJ_CTRL_HOME/tb/image/tb_tj_image_format.sv" && \
    vcs -full64 -nc tb_tj_image_format -o simv && \
    ./simv -nc +CFG="$IMAGE_CASE/lvds_config.txt" +IMG="$WORK/image/out/send_image.bin" \
      +MEMCFG="$IMAGE_CASE/die_0_0/0_2_mem_config.txt" \
      +BOOT="$WORK/image/out/boot_prim_die_0_0_0_2.bin" ) > "$WORK/image/run.log" 2>&1 && \
    sim_passed "$WORK/image/run.log" "IMAGE FORMAT TB"; then
    say "    $(grep 'IMAGE FORMAT TB PASS' "$WORK/image/run.log")"
  else
    bad "镜像格式构建或测试失败(见 $WORK/image/run.log)"
  fi
fi

# Initialization command replay with the single-die SPI model.
INIT_CASE=${INIT_CASE:-/data_8T_2/Tianjic/all_cases/die_extern/resnet9_lvds}
if [ ! -d "$INIT_CASE" ]; then
  say "[8/12] Initialization replay: skipped (case directory not found: $INIT_CASE)"
else
  say "[8/12] Single-die initialization replay (APB -> SPIWIN -> SPI -> spi2ahb)"
  mkdir -p "$WORK/init"
  if ( INIT_CASE=$(cd "$INIT_CASE" && pwd) && \
    python3 "$TJ_CTRL_HOME/sw/tj_image.py" export "$INIT_CASE" \
      -o "$WORK/init/image" && \
    cd "$WORK/init" && \
    vlogan -full64 -sverilog -nc -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
      "$YAWING_DESIGN/rtl/mcu_subsys/spi/spi2ahb.v" \
      "$TJ_CTRL_HOME/tb/init/tb_tj_init_replay.sv" && \
    vcs -full64 -nc tb_tj_init_replay -o simv && \
    ./simv -nc +REGS="$WORK/init/image/init_regs.txt" ) > "$WORK/init/run.log" 2>&1 && \
    sim_passed "$WORK/init/run.log" "INIT REPLAY TB"; then
    say "    $(grep 'INIT REPLAY TB PASS' "$WORK/init/run.log")"
  else
    bad "Initialization replay build or test failed (see $WORK/init/run.log)"
  fi
fi

# LVDS link test.
echo
if [ "${SKIP_LNK:-0}" = "1" ]; then
  say "[9/12] LVDS 链路验收 TB:跳过(SKIP_LNK=1)"
elif [ ! -f "$YAWING_DESIGN/rtl/lvds_subsys/top/lvds_subsys.sv" ]; then
  say "[9/12] LVDS 链路验收 TB:芯片 lvds 树不可达,跳过"
else
  say "[9/12] LVDS 链路验收 TB(链主机 + 两份芯片原版 lvds_subsys 对打,T1-T4)"
  if sh "$TJ_CTRL_HOME/tb/lnk/run_lnk_tb.sh" "$WORK/lnk" > "$WORK/lnk_run.log" 2>&1; then
    say "    $(grep -E '(LNK|CFGCHAIN) TB PASS' "$WORK/lnk_run.log")"
  else
    bad "LVDS 链路 TB 未 PASS(见 $WORK/lnk_run.log)"
  fi
fi

# SEND path test.
echo
say "[10/12] SEND 验收 TB(APB门铃→AXI取数→解析分发→缝TX,九相位;含 导出镜像重放)"
mkdir -p "$WORK/send"
IMG_ARG=""
[ -f "$WORK/image/out/send_image.bin" ] && IMG_ARG="+IMG=$WORK/image/out/send_image.bin"
if ( cd "$WORK/send" && \
  vlogan -full64 -sverilog -nc -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
    "$TJ_CTRL_HOME/tb/send/tj_send_verification_top.sv" \
    "$TJ_CTRL_HOME/tb/send/tb_tj_send.sv" && \
  vcs -full64 -nc tb_tj_send -o simv && \
  ./simv -nc $IMG_ARG ) > "$WORK/send/run.log" 2>&1 && \
  sim_passed "$WORK/send/run.log" "SEND TB"; then
  say "    $(grep 'SEND TB PASS' "$WORK/send/run.log")${IMG_ARG:+(含镜像重放)}"
else
  bad "SEND TB 未 PASS(见 $WORK/send/run.log)"
fi

# RECV path test.
echo
say "[11/12] RECV 验收 TB(缝RX→环形写→host消费,九相位;含 SEND→RECV 环回)"
mkdir -p "$WORK/recv"
if ( cd "$WORK/recv" && \
  vlogan -full64 -sverilog -nc -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
    "$TJ_CTRL_HOME/tb/recv/tb_tj_recv.sv" && \
  vcs -full64 -nc tb_tj_recv -o simv && \
  ./simv -nc ) > "$WORK/recv/run.log" 2>&1 && \
  sim_passed "$WORK/recv/run.log" "RECV TB"; then
  say "    $(grep 'RECV TB PASS' "$WORK/recv/run.log")"
else
  bad "RECV TB 未 PASS(见 $WORK/recv/run.log)"
fi

# BOOT data loading through SPI.
boot_profile() {
  if ( cd "$WORK/boot" && ./simv -nc "+TJ_PCLK_HP=$2" "+TJ_MAXI_HP=$3" ) \
       > "$WORK/boot/$1" 2>&1 && sim_passed "$WORK/boot/$1" "BOOT TB"; then
    say "    $1: $(grep '^BOOT TB PASS' "$WORK/boot/$1")"
  else
    bad "BOOT TB failed (see $WORK/boot/$1)"
  fi
}
say "[12/12] BOOT 引擎测试"
mkdir -p "$WORK/boot"
if ( cd "$WORK/boot" && \
  vlogan -full64 -sverilog -nc -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
    "$YAWING_DESIGN/rtl/mcu_subsys/spi/spi2ahb.v" \
    "$TJ_CTRL_HOME/tb/boot/tb_tj_boot.sv" && \
  vcs -full64 -nc tb_tj_boot -o simv ) > "$WORK/boot/build.log" 2>&1 &&
  log_clean "$WORK/boot/build.log"; then
  boot_profile run.log          5.0   1.2
  boot_profile run_delivery.log 2.0  10.0
  boot_profile run_boundary.log 50.0  5.0
else
  bad "BOOT TB build failed (see $WORK/boot/build.log)"
fi

# Overall result.
echo
if [ $FAIL -eq 0 ]; then
  say "回归全绿(工作目录 $WORK)"
  exit 0
else
  say "回归有红,逐条见上方 ** FAIL"
  exit 1
fi
