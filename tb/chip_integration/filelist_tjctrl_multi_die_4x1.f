// Native multi-die environment and the Controller testbench.
// Select the 4x1 UVM tests before including the native environment.
+incdir+$TJ_CTRL_HOME/tb/chip_integration/multi_die_4x1_overlay
-f $DESIGN_ROOT/multi_die/filelist/filelist.f

// Shared Controller RTL, including BOOT and the read arbiter.
-f $TJ_CTRL_HOME/flist/tj_ctrl_cosim.f

$TJ_CTRL_HOME/tb/chip_integration/tb_tj_ctrl_chip.sv
