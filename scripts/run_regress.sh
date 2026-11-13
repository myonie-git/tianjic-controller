#!/bin/sh
# Run Controller regression tests, lint and CDC checks.
# Usage: sh controller/scripts/run_regress.sh
# REGRESS_TESTS selects stages; empty runs the existing full sequence.
# *_CASES selects comma-separated scene IDs for that testbench.
# JITTER_TESTS selects SEND/RECV/BOOT within the jitter stage (default: all three).
# SEND_IMG supplies a record image when running SEND without the image stage.
# Requires Python 3 and VCS in PATH; SpyGlass is optional.
# REGRESS_WORK selects the output directory, which is cleared before each run.
# INIT_CASE selects the initialization replay case.
# SEEDS overrides SPI and bypass seeds; EXTRA_SEEDS appends more.
# DSEEDS selects seeds for SEND, RECV and BOOT.
# JSEEDS selects seeds for the three-clock-ratio CDC jitter runs.
# SKIP_APB_SMOKE, SKIP_SG and SKIP_LNK skip the corresponding stages.
# PROFILE_SIMULATOR selects vcs (default) or questa for the profiles stage.
# LNK_SIMULATOR selects vcs (default) or questa for lnk/tlast/cfgchain.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
export TJ_CTRL_HOME=$(dirname "$SCRIPT_DIR")
REPO=$(dirname "$TJ_CTRL_HOME")
export YAWING_DESIGN=${YAWING_DESIGN:-$REPO/soc/design}
export TIANJIC_A_DESIGN=${TIANJIC_A_DESIGN:-$REPO/design}
WORK=${REGRESS_WORK:-/tmp/tj_regress_$(id -un)}
SEEDS=${SEEDS:-"default 31 166 336 7 99"}${EXTRA_SEEDS:+" $EXTRA_SEEDS"}
DSEEDS=${DSEEDS:-"default 31 166 7"}
JSEEDS=${JSEEDS:-"1 2 3 4 5 6 7 8"}
REGRESS_TESTS=$(printf '%s' "${REGRESS_TESTS:-}" | tr ',' ' ')
JITTER_TESTS=${JITTER_TESTS:-"send recv boot"}
FAIL=0

say()  { printf '%s\n' "== $*"; }
bad()  { printf '%s\n' "** FAIL: $*"; FAIL=1; }

# Empty stage selection preserves the default run.
selected() {
  [ -z "$REGRESS_TESTS" ] && return 0
  case " $REGRESS_TESTS " in *" $1 "*) return 0 ;; esac
  return 1
}
for stage in $REGRESS_TESTS; do
  case "$stage" in
    gen|csr|spi|top|apb_smoke|static|image|init|lnk|tlast|cfgchain|send|recv|boot|bypass|bypass_disabled|bypass_csr|jitter|profiles) ;;
    *) printf 'Unknown REGRESS_TESTS stage: %s\n' "$stage" >&2; exit 2 ;;
  esac
done

# A PASS line must have real checks and no accompanying failure diagnostics.
log_clean() {
  ! grep -Eq '(^|[[:space:]])(FAIL|TIMEOUT)([[:space:]:]|$)|^[[:space:]]*(Fatal:|Error[-:])' "$1"
}
sim_passed() {
  grep -Eq "^$2 PASS \\([1-9][0-9]* checks\\)$" "$1" && log_clean "$1"
}

rm -rf "$WORK"; mkdir -p "$WORK/gen" "$WORK/csr" "$WORK/spi" "$WORK/top" "$WORK/apb_smoke" "$WORK/sg"

if selected gen; then
  # CSR generated files.
  say "[1/14] 生成物防漂移门禁"
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

else
  say "SKIP gen (not selected)"
fi

if selected csr; then
  # CSR register test.
  say "[2/14] CSR 自测 TB"
  if ( cd "$WORK/csr" && \
    vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" -timescale=1ns/1ps \
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

else
  say "SKIP csr (not selected)"
fi

if selected spi; then
  # SPI tests across seeds.
  say "[3/14] SPI 陪练 TB × 种子集 [$SEEDS]"
  ( cd "$WORK/spi" && \
    vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" +define+TJ_ASSERT_ON -timescale=1ns/1ps \
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
    if ( cd "$WORK/spi" && ./simv -nc $arg ${SPI_CASES:+"+TJ_CASES=$SPI_CASES"} ) > "$WORK/spi/run_$s.log" 2>&1 && \
      sim_passed "$WORK/spi/run_$s.log" "SPI TB"; then
      n_pass=$((n_pass+1))
    else
      bad "SPI TB seed=$s 未 PASS(见 $WORK/spi/run_$s.log)"
    fi
  done
  n_seed=$(echo $SEEDS | wc -w)
  [ "$n_pass" = "$n_seed" ] && say "    全种子($n_pass/$n_seed) $(grep -h 'SPI TB PASS' "$WORK"/spi/run_*.log | sort -u)"

else
  say "SKIP spi (not selected)"
fi

if selected top; then
  # Top-level elaboration.
  say "[4/14] 顶层弹性"
  ( cd "$WORK/top" && \
    vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" && \
    vcs -full64 -nc tj_ctrl_top -o simv ) > "$WORK/top/run.log" 2>&1 \
    && log_clean "$WORK/top/run.log" && say "    TOP ELAB OK" || bad "顶层弹性失败(见 $WORK/top/run.log)"

else
  say "SKIP top (not selected)"
fi

if selected apb_smoke; then
  # Compile Controller and chip RTL together, then run the APB smoke test.
  if [ "${SKIP_APB_SMOKE:-0}" = "1" ]; then
    say "[5/14] APB 共库冒烟:SKIP_APB_SMOKE=1 跳过"
  else
    say "[5/14] APB 共库编译及APB冒烟"
    # Match the native chip build's duplicate-module policy.
    if ( cd "$WORK/apb_smoke" && \
      vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" && \
      vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" -timescale=1ns/1ps +error+5000 -error=noMPD \
        -f "$YAWING_DESIGN/flist/chip_top_tianjic.sim.f" && \
      vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" -timescale=1ns/1ps "$TJ_CTRL_HOME/tb/top/tb_tj_ctrl_apb_smoke.sv" && \
      vcs -full64 -nc tb_tj_ctrl_apb_smoke -o simv && ./simv -nc ) > "$WORK/apb_smoke/run.log" 2>&1 && \
      sim_passed "$WORK/apb_smoke/run.log" "CTRL APB SMOKE TB"; then
      say "    CTRL APB SMOKE TB PASS"
    else
      bad "APB 冒烟编译或仿真失败(见 $WORK/apb_smoke/run.log)"
    fi
  fi
else
  say "SKIP apb_smoke (not selected)"
fi

# Check the severity fields in a SpyGlass report.
sg_report() {
  sg_rpt=$(find "$1" -name moresimple.rpt 2>/dev/null | head -1)
  if [ ! -s "$sg_rpt" ]; then
    bad "$2 did not produce a report (see $1/run.log)"
  elif ! sg_nerr=$(awk '
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
  ' "$sg_rpt"); then
    bad "$2 report could not be read ($sg_rpt)"
  elif [ "$sg_nerr" -gt 0 ]; then
    bad "$2 reported $sg_nerr errors ($sg_rpt)"
  else
    say "    $2: 0 errors (warnings: $sg_rpt)"
  fi
}

if selected static; then
  # SpyGlass lint and CDC structure checks.
  if [ "${SKIP_SG:-0}" = "1" ] || ! command -v spyglass >/dev/null 2>&1; then
    say "[6/14] SpyGlass lint/CDC: skipped (SKIP_SG=1 or tool unavailable)"
  else
    say "[6/14] SpyGlass lint and CDC structure checks"
    sed "s|\${TJ_CTRL_HOME}|$TJ_CTRL_HOME|g" "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
      > "$WORK/sg/expanded.f"
    cat > "$WORK/sg/tj.prj" <<EOF
#!SPYGLASS_PROJECT_FILE
#!VERSION 3.0
set_option projectwdir $WORK/sg
set_option language_mode mixed
set_option mthresh 131072
set_option enableSV09 yes
set_option top tj_ctrl_top
read_file -type sourcelist $WORK/sg/expanded.f
EOF
    if ( cd "$WORK/sg" && spyglass -project tj.prj -goal lint/lint_rtl -batch ) \
         > "$WORK/sg/run.log" 2>&1; then
      sg_report "$WORK/sg" "SpyGlass lint"
    else
      bad "SpyGlass lint execution failed (see $WORK/sg/run.log)"
    fi

    mkdir -p "$WORK/cdc"
    cat > "$WORK/cdc/tj_cdc.prj" <<EOF
#!SPYGLASS_PROJECT_FILE
#!VERSION 3.0
set_option projectwdir $WORK/cdc
set_option language_mode mixed
set_option mthresh 131072
set_option enableSV09 yes
set_option top tj_ctrl_top
read_file -type sourcelist $WORK/sg/expanded.f
read_file -type sgdc $TJ_CTRL_HOME/scripts/tj_ctrl.sgdc
EOF
    if ( cd "$WORK/cdc" && spyglass -project tj_cdc.prj -goal cdc/cdc_verify_struct -batch ) \
         > "$WORK/cdc/run.log" 2>&1; then
      sg_report "$WORK/cdc" "SpyGlass CDC"
    else
      bad "SpyGlass CDC execution failed (see $WORK/cdc/run.log)"
    fi

    # The shell-level SPI bypass is not instantiated by tj_ctrl_top.
    cat > "$WORK/sg/bypass_files.f" <<EOF
$TJ_CTRL_HOME/rtl/common/tj_cdc.sv
$TJ_CTRL_HOME/rtl/spi/tj_bypass_spi.sv
$TJ_CTRL_HOME/tb/bypass/tj_bypass_static_top.sv
EOF
    for bypass_goal in lint/lint_rtl cdc/cdc_verify_struct; do
      bypass_tag=$(printf '%s' "$bypass_goal" | tr '/' '_')
      bypass_dir="$WORK/sg_bypass_$bypass_tag"
      mkdir -p "$bypass_dir"
      cat > "$bypass_dir/prj.prj" <<EOF
#!SPYGLASS_PROJECT_FILE
#!VERSION 3.0
set_option projectwdir $bypass_dir
set_option language_mode mixed
set_option enableSV09 yes
set_option top tj_bypass_static_top
read_file -type sourcelist $WORK/sg/bypass_files.f
read_file -type sgdc $TJ_CTRL_HOME/scripts/tj_bypass.sgdc
EOF
      if ( cd "$bypass_dir" && spyglass -project prj.prj -goal "$bypass_goal" -batch ) \
           > "$bypass_dir/run.log" 2>&1; then
        sg_report "$bypass_dir" "SpyGlass bypass ($bypass_goal)"
      else
        bad "SpyGlass bypass ($bypass_goal) execution failed (see $bypass_dir/run.log)"
      fi
    done
  fi

else
  say "SKIP static (not selected)"
fi

if selected image; then
  # Image exporter CLI and SV format checks.
  say "[7/14] 镜像工具与格式检查"
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
      vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" -timescale=1ns/1ps \
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

else
  say "SKIP image (not selected)"
fi

if selected init; then
  # Initialization command replay through SPI-to-AHB models.
  INIT_CASE=${INIT_CASE:-/data_8T_2/Tianjic/all_cases/die_extern/resnet9_lvds}
  if [ ! -d "$INIT_CASE" ]; then
    say "[8/14] Initialization replay: skipped (case directory not found: $INIT_CASE)"
  else
    say "[8/14] Initialization replay (APB -> SPIWIN -> SPI -> spi2ahb)"
    mkdir -p "$WORK/init"
    if ( INIT_CASE=$(cd "$INIT_CASE" && pwd) && \
      python3 "$TJ_CTRL_HOME/sw/tj_image.py" export "$INIT_CASE" \
        -o "$WORK/init/image" && \
      cd "$WORK/init" && \
      vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" +define+TJ_ASSERT_ON -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
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

else
  say "SKIP init (not selected)"
fi

if selected lnk || selected tlast || selected cfgchain; then
  # LVDS link test.
  echo
  if [ "${SKIP_LNK:-0}" = "1" ]; then
    say "[9/14] LVDS 链路验收 TB:跳过(SKIP_LNK=1)"
  elif [ ! -f "$TJ_CTRL_HOME/rtl/lvds/top/lvds_subsys.sv" ]; then
    bad "[9/14] Controller LVDS 源码缺失"
  else
    lnk_tests=""
    if selected lnk; then
      lnk_tests="$lnk_tests lnk tlast"
    elif selected tlast; then
      lnk_tests="$lnk_tests tlast"
    fi
    selected cfgchain && lnk_tests="$lnk_tests cfgchain"
    say "[9/14] LVDS/配置链验收 TB:$lnk_tests"
    if LNK_TESTS="$lnk_tests" sh "$TJ_CTRL_HOME/tb/lnk/run_lnk_tb.sh" "$WORK/lnk" > "$WORK/lnk_run.log" 2>&1; then
      say "    $(grep -E '(LNK|TLAST|CFGCHAIN) TB PASS' "$WORK/lnk_run.log")"
    else
      bad "LVDS 链路 TB 未 PASS(见 $WORK/lnk_run.log)"
    fi
  fi
else
  say "SKIP lnk/tlast/cfgchain (not selected)"
fi

# Run each data-path seed using the same compiled simulator.
data_runs() {
  data_dir=$1
  data_name=$2
  data_label=$3
  data_seeds=$4
  shift 4
  data_first=1
  for data_seed in $data_seeds; do
    data_arg=""
    [ "$data_seed" = "default" ] || data_arg="+ntb_random_seed=$data_seed"
    if [ "$data_first" -eq 1 ]; then
      data_log="$data_dir/$data_label.log"
      data_first=0
    else
      data_log="$data_dir/${data_label}_$data_seed.log"
    fi
    if ( cd "$data_dir" && ./simv -nc $data_arg "$@" ) > "$data_log" 2>&1 &&
         sim_passed "$data_log" "$data_name"; then
      say "    $data_name $data_label seed=$data_seed: $(grep "^$data_name PASS" "$data_log")"
    else
      bad "$data_name $data_label seed=$data_seed failed (see $data_log)"
    fi
  done
}

if selected send; then
  # SEND path test.
  echo
  say "[10/14] SEND path test"
  mkdir -p "$WORK/send"
  IMG_ARG=""
  if [ -n "${SEND_IMG:-}" ]; then
    IMG_ARG="+IMG=$SEND_IMG"
  elif [ -f "$WORK/image/out/send_image.bin" ]; then
    IMG_ARG="+IMG=$WORK/image/out/send_image.bin"
  fi
  send_extra_img=""
  [ -n "${SEND_CASES:-}" ] && send_extra_img="$IMG_ARG"
  if ( cd "$WORK/send" && \
    vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
      "$TJ_CTRL_HOME/tb/send/tj_send_verification_top.sv" \
      "$TJ_CTRL_HOME/tb/send/tb_tj_send.sv" && \
    vcs -full64 -nc tb_tj_send -o simv ) > "$WORK/send/build.log" 2>&1 &&
    log_clean "$WORK/send/build.log"; then
    data_runs "$WORK/send" "SEND TB" run "$DSEEDS" ${IMG_ARG:+"$IMG_ARG"} ${SEND_CASES:+"+TJ_CASES=$SEND_CASES"}
    data_runs "$WORK/send" "SEND TB" run_delivery default +TJ_PCLK_HP=2.0 +TJ_MAXI_HP=10.0 ${SEND_CASES:+"+TJ_CASES=$SEND_CASES"} ${send_extra_img:+"$send_extra_img"}
    data_runs "$WORK/send" "SEND TB" run_boundary default +TJ_PCLK_HP=50.0 +TJ_MAXI_HP=5.0 ${SEND_CASES:+"+TJ_CASES=$SEND_CASES"} ${send_extra_img:+"$send_extra_img"}
  else
    bad "SEND TB build failed (see $WORK/send/build.log)"
  fi

else
  say "SKIP send (not selected)"
fi

if selected recv; then
  # RECV path test.
  echo
  say "[11/14] RECV path test"
  mkdir -p "$WORK/recv"
  if ( cd "$WORK/recv" && \
    vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
      "$TJ_CTRL_HOME/tb/recv/tb_tj_recv.sv" && \
    vcs -full64 -nc tb_tj_recv -o simv ) > "$WORK/recv/build.log" 2>&1 &&
    log_clean "$WORK/recv/build.log"; then
    data_runs "$WORK/recv" "RECV TB" run "$DSEEDS" ${RECV_CASES:+"+TJ_CASES=$RECV_CASES"}
    data_runs "$WORK/recv" "RECV TB" run_delivery default +TJ_PCLK_HP=2.0 +TJ_MAXI_HP=10.0 ${RECV_CASES:+"+TJ_CASES=$RECV_CASES"}
    data_runs "$WORK/recv" "RECV TB" run_boundary default +TJ_PCLK_HP=50.0 +TJ_MAXI_HP=5.0 ${RECV_CASES:+"+TJ_CASES=$RECV_CASES"}
  else
    bad "RECV TB build failed (see $WORK/recv/build.log)"
  fi

else
  say "SKIP recv (not selected)"
fi

if selected boot; then
  # BOOT data loading through SPI, at all three clock ratios.
  say "[12/14] BOOT engine test"
  mkdir -p "$WORK/boot"
  if ( cd "$WORK/boot" && \
    vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" +define+TJ_ASSERT_ON -timescale=1ns/1ps -f "$TJ_CTRL_HOME/flist/tj_ctrl.f" \
      "$YAWING_DESIGN/rtl/mcu_subsys/spi/spi2ahb.v" \
      "$TJ_CTRL_HOME/tb/boot/tb_tj_boot.sv" && \
    vcs -full64 -nc tb_tj_boot -o simv ) > "$WORK/boot/build.log" 2>&1 &&
    log_clean "$WORK/boot/build.log"; then
    data_runs "$WORK/boot" "BOOT TB" run          "$DSEEDS" +TJ_PCLK_HP=5.0  +TJ_MAXI_HP=1.2 ${BOOT_CASES:+"+TJ_CASES=$BOOT_CASES"}
    data_runs "$WORK/boot" "BOOT TB" run_delivery "$DSEEDS" +TJ_PCLK_HP=2.0  +TJ_MAXI_HP=10.0 ${BOOT_CASES:+"+TJ_CASES=$BOOT_CASES"}
    data_runs "$WORK/boot" "BOOT TB" run_boundary "$DSEEDS" +TJ_PCLK_HP=50.0 +TJ_MAXI_HP=5.0 ${BOOT_CASES:+"+TJ_CASES=$BOOT_CASES"}
  else
    bad "BOOT TB build failed (see $WORK/boot/build.log)"
  fi

else
  say "SKIP boot (not selected)"
fi

if selected bypass || selected bypass_disabled; then
  # SPI slave framing and APB arbitration.
  echo
  say "[13/14] Bypass SPI slave test"
  mkdir -p "$WORK/bypass"
  if ( cd "$WORK/bypass" && \
    vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" +define+TJ_ASSERT_ON -timescale=1ns/1ps \
      "$TJ_CTRL_HOME/rtl/common/tj_cdc.sv" \
      "$TJ_CTRL_HOME/rtl/spi/tj_bypass_spi.sv" \
      "$TJ_CTRL_HOME/tb/bypass/tb_tj_bypass.sv" && \
    vcs -full64 -nc tb_tj_bypass -o simv ) > "$WORK/bypass/build.log" 2>&1 &&
    log_clean "$WORK/bypass/build.log"; then
    if selected bypass; then
      data_runs "$WORK/bypass" "BYPASS TB" run "$SEEDS" ${BYPASS_CASES:+"+TJ_CASES=$BYPASS_CASES"}
    else
      say "SKIP bypass (not selected)"
    fi
    # Reuse the compiled sources to elaborate the disabled configuration.
    if selected bypass_disabled; then
    if ( cd "$WORK/bypass" && \
      vcs -full64 -nc tb_tj_bypass -pvalue+tb_tj_bypass.ENABLE_BYPASS_SPI=0 \
        -o simv_disabled ) > "$WORK/bypass/build_disabled.log" 2>&1 &&
      log_clean "$WORK/bypass/build_disabled.log" &&
      ( cd "$WORK/bypass" && ./simv_disabled -nc ) > "$WORK/bypass/run_disabled.log" 2>&1 &&
      sim_passed "$WORK/bypass/run_disabled.log" "BYPASS TB"; then
      say "    Bypass disabled: $(grep '^BYPASS TB PASS' "$WORK/bypass/run_disabled.log")"
    else
      bad "Disabled bypass test failed (see $WORK/bypass/build_disabled.log and run_disabled.log)"
    fi
    else
      say "SKIP bypass_disabled (not selected)"
    fi
  else
    bad "Bypass SPI TB build failed (see $WORK/bypass/build.log)"
  fi

else
  say "SKIP bypass/bypass_disabled (not selected)"
fi

if selected bypass_csr; then
  # SPI accesses to the generated CSR block.
  mkdir -p "$WORK/bypass"
  if ( cd "$WORK/bypass" && \
    vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" +define+TJ_ASSERT_ON -timescale=1ns/1ps \
      "$TJ_CTRL_HOME/rtl/csr/tj_ctrl_csr_pkg.sv" \
      "$TJ_CTRL_HOME/rtl/csr/tj_ctrl_csr.sv" \
      "$TJ_CTRL_HOME/rtl/common/tj_cdc.sv" \
      "$TJ_CTRL_HOME/rtl/spi/tj_bypass_spi.sv" \
      "$TJ_CTRL_HOME/tb/bypass/tb_tj_bypass_csr.sv" && \
    vcs -full64 -nc tb_tj_bypass_csr -o simv_csr ) > "$WORK/bypass/build_csr.log" 2>&1 &&
    log_clean "$WORK/bypass/build_csr.log" &&
    ( cd "$WORK/bypass" && ./simv_csr -nc ${BYPASS_CSR_CASES:+"+TJ_CASES=$BYPASS_CSR_CASES"} ) > "$WORK/bypass/run_csr.log" 2>&1 &&
    sim_passed "$WORK/bypass/run_csr.log" "BYPASS CSR TB"; then
    say "    $(grep '^BYPASS CSR TB PASS' "$WORK/bypass/run_csr.log")"
  else
    bad "Bypass CSR test failed (see $WORK/bypass/build_csr.log and run_csr.log)"
  fi

else
  say "SKIP bypass_csr (not selected)"
fi

if selected jitter; then
  # CDC sampling-delay model: each data-path test uses all three clock ratios.
  echo
  say "[14/14] CDC jitter tests"
  mkdir -p "$WORK/jit"
  cdc_ports() {
    awk '/^[[:space:]]*\/\//{next}
         /^module /{m=$2; sub(/[ #(].*/,"",m); print "module " m; h=1; next}
         h && /\);/ {h=0}
         h && /(parameter|input|output)/ {l=$0; sub(/\/\/.*/,"",l); sub(/=.*/,"",l);
           gsub(/[[:space:]]+/," ",l); sub(/,[ ]*$/,"",l); sub(/^ /,"",l); sub(/ $/,"",l); print "  " l}' "$1"
  }
  cdc_ports "$TJ_CTRL_HOME/rtl/common/tj_cdc.sv"    > "$WORK/jit/ports_rtl.txt"
  cdc_ports "$TJ_CTRL_HOME/tb/common/tj_cdc_jit.sv" > "$WORK/jit/ports_jit.txt"
  if [ -s "$WORK/jit/ports_rtl.txt" ] && diff "$WORK/jit/ports_rtl.txt" "$WORK/jit/ports_jit.txt" > "$WORK/jit/ports.diff" 2>&1; then
    :
  else
    bad "CDC model module/port mismatch (see $WORK/jit/ports.diff)"
  fi
  grep -v '^[[:space:]]*//' "$TJ_CTRL_HOME/flist/tj_ctrl.f" | grep -v '^[[:space:]]*$' \
    | sed "s|\${TJ_CTRL_HOME}/rtl/common/tj_cdc.sv|$TJ_CTRL_HOME/tb/common/tj_cdc_jit.sv|" \
    > "$WORK/jit/jit.f"
  grep -q 'tj_cdc_jit.sv' "$WORK/jit/jit.f" || bad "CDC model file-list replacement failed"

  for tb in $JITTER_TESTS; do
    case "$tb" in
      send) jitter_cases=${SEND_CASES:-} ;;
      recv) jitter_cases=${RECV_CASES:-} ;;
      boot) jitter_cases=${BOOT_CASES:-} ;;
      *) bad "Unknown JITTER_TESTS module: $tb"; continue ;;
    esac
    jitter_img=""
    if [ "$tb" = send ] && [ -n "$jitter_cases" ]; then
      if [ -n "${SEND_IMG:-}" ]; then
        jitter_img="+IMG=$SEND_IMG"
      elif [ -f "$WORK/image/out/send_image.bin" ]; then
        jitter_img="+IMG=$WORK/image/out/send_image.bin"
      fi
    fi
    tb_name=$(printf '%s' "$tb" | tr a-z A-Z)
    extra=""
    defines=""
    [ "$tb" = boot ] && extra="$YAWING_DESIGN/rtl/mcu_subsys/spi/spi2ahb.v" && defines="+define+TJ_ASSERT_ON"
    [ "$tb" = send ] && extra="$TJ_CTRL_HOME/tb/send/tj_send_verification_top.sv"
    mkdir -p "$WORK/jit/$tb"
    if ( cd "$WORK/jit/$tb" &&
      vlogan -full64 -sverilog -nc "+incdir+$TJ_CTRL_HOME/tb/common" $defines -timescale=1ns/1ps -f "$WORK/jit/jit.f" \
        $extra "$TJ_CTRL_HOME/tb/$tb/tb_tj_$tb.sv" &&
      vcs -full64 -nc "tb_tj_$tb" -o simv ) > "$WORK/jit/$tb/build.log" 2>&1 &&
      log_clean "$WORK/jit/$tb/build.log"; then
      data_runs "$WORK/jit/$tb" "$tb_name TB" run          "$JSEEDS" +TJ_PCLK_HP=5.0  +TJ_MAXI_HP=1.2 ${jitter_cases:+"+TJ_CASES=$jitter_cases"} ${jitter_img:+"$jitter_img"}
      data_runs "$WORK/jit/$tb" "$tb_name TB" run_delivery "$JSEEDS" +TJ_PCLK_HP=2.0  +TJ_MAXI_HP=10.0 ${jitter_cases:+"+TJ_CASES=$jitter_cases"} ${jitter_img:+"$jitter_img"}
      data_runs "$WORK/jit/$tb" "$tb_name TB" run_boundary "$JSEEDS" +TJ_PCLK_HP=50.0 +TJ_MAXI_HP=5.0 ${jitter_cases:+"+TJ_CASES=$jitter_cases"} ${jitter_img:+"$jitter_img"}
    else
      bad "CDC jitter $tb_name build failed (see $WORK/jit/$tb/build.log)"
    fi
  done
else
  say "SKIP jitter (not selected)"
fi

# Both supported CSR/SPI configurations use the same production RTL.
if selected profiles; then
  if python3 "$TJ_CTRL_HOME/tb/spi/run_profiles.py" --simulator "${PROFILE_SIMULATOR:-vcs}" --work "$WORK/profiles"; then
    say "CSR/SPI profiles passed"
  else
    bad "CSR/SPI profile regression failed (see $WORK/profiles)"
  fi
fi

# Overall result.
echo
if [ $FAIL -eq 0 ]; then
  say "Regression passed (work directory: $WORK)"
  exit 0
else
  say "Regression failed. See ** FAIL messages above."
  exit 1
fi
