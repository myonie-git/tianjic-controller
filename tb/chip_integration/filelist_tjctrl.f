// Native chip testbench, RTL and model dependencies.
-f $DESIGN_ROOT/full_chip_subsys/filelist/filelist_tianjic.f

// Controller RTL and LVDS adapters; chip dependencies are supplied above.
-f $TJ_CTRL_HOME/flist/tj_ctrl_cosim.f

// Controller-side integration testbench.
$TJ_CTRL_HOME/tb/chip_integration/tb_tj_ctrl_chip.sv
