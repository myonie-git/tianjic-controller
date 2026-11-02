# BOOT block address, pclk to maxi_clk. Set TJ_BOOT_MAXI_PERIOD in ns after defining clocks.
# Only the first request synchronizer stage samples the asynchronous toggle.
set_false_path -from [get_cells -hierarchical -filter {full_name =~ *u_boot/u_engine/f_req_tgl_reg*}] \
               -to   [get_cells -hierarchical -filter {full_name =~ *u_boot/u_fetch/req_syn_q_reg?0?}]

set_max_delay $TJ_BOOT_MAXI_PERIOD \
  -from [get_cells -hierarchical -filter {full_name =~ *u_boot/u_engine/f_blk_addr_reg*}] \
  -to   [get_cells -hierarchical -filter {full_name =~ *u_boot/u_fetch/addr_q_reg*}]
