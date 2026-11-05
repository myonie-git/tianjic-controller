# Common CDC paths in tj_ctrl_top for Vivado.
# Load with the five per-path constraints listed in the Controller README.

set tj_sync2_first [get_cells -hier -filter {NAME =~ */meta_q_reg*}]
set tj_sync2_outputs [get_pins -of_objects $tj_sync2_first -filter {REF_PIN_NAME == Q}]
set tj_sync2_second [all_fanout -flat -endpoints_only -only_cells $tj_sync2_outputs]
set_property ASYNC_REG TRUE $tj_sync2_first
set_property ASYNC_REG TRUE $tj_sync2_second
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ */syn_q_reg*}]
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ */s0_q_reg* || NAME =~ */s1_q_reg* || NAME =~ */s2_q_reg*}]
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *u_boot/u_fetch/req_syn_q_reg* || NAME =~ *u_boot/u_engine/ack_s1_q_reg* || NAME =~ *u_boot/u_engine/ack_s2_q_reg*}]

set_false_path -to [get_cells -hier -filter {NAME =~ */meta_q_reg*}]
set_false_path -from [get_cells -hier -filter {NAME =~ */tgl_q_reg*}] \
               -to   [get_cells -hier -filter {NAME =~ */syn_q_reg?0?}]
set_false_path -from [get_cells -hier -filter {NAME =~ */tgl_q_reg*}] \
               -to   [get_cells -hier -filter {NAME =~ */s0_q_reg*}]
set_false_path -from [get_cells -hier -filter {NAME =~ *u_boot/u_fetch/ack_tgl_reg*}] \
               -to   [get_cells -hier -filter {NAME =~ *u_boot/u_engine/ack_s1_q_reg*}]

# Bound only the BOOT return paths from maxi_clk to the pclk engine.
set_max_delay $TJ_BOOT_PCLK_PERIOD -datapath_only \
  -from [get_cells -hier -filter {NAME =~ *u_boot/u_fetch/blk_reg* || NAME =~ *u_boot/u_fetch/blk_err_reg*}] \
  -to   [get_cells -hier -filter {NAME =~ *u_boot/u_engine/*_reg*}]
