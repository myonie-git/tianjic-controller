# Common CDC paths in tj_ctrl_top for Synopsys DC/PrimeTime.
# Load with the five per-path constraints listed in the Controller README.

set_false_path -to [get_cells -hierarchical -filter {full_name =~ */meta_q_reg*}]
set_false_path -from [get_cells -hierarchical -filter {full_name =~ */tgl_q_reg*}] \
               -to   [get_cells -hierarchical -filter {full_name =~ */syn_q_reg?0?}]
set_false_path -from [get_cells -hierarchical -filter {full_name =~ */tgl_q_reg*}] \
               -to   [get_cells -hierarchical -filter {full_name =~ */s0_q_reg*}]
set_false_path -from [get_cells -hierarchical -filter {full_name =~ *u_boot/u_fetch/ack_tgl_reg*}] \
               -to   [get_cells -hierarchical -filter {full_name =~ *u_boot/u_engine/ack_s1_q_reg*}]

# Bound only the BOOT return paths from maxi_clk to the pclk engine.
set tj_boot_return_src [get_cells -hierarchical -filter {full_name =~ *u_boot/u_fetch/blk_reg* || full_name =~ *u_boot/u_fetch/blk_err_reg*}]
set tj_boot_return_dst [get_cells -hierarchical -filter {full_name =~ *u_boot/u_engine/*_reg*}]
set_max_delay $TJ_BOOT_PCLK_PERIOD -from $tj_boot_return_src -to $tj_boot_return_dst
set_min_delay 0 -from $tj_boot_return_src -to $tj_boot_return_dst
unset tj_boot_return_src tj_boot_return_dst
