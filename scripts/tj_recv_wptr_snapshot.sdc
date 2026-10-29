# RECV WPTR snapshot constraints for Synopsys SDC.
# Source after defining clocks and TJ_RECV_PCLK_PERIOD in ns.
set_false_path -to [get_cells -hierarchical -filter {full_name =~ *u_wp/u_req/meta_q_reg*}]
set_false_path -to [get_cells -hierarchical -filter {full_name =~ *u_wp/u_ack/meta_q_reg*}]
set_max_delay $TJ_RECV_PCLK_PERIOD \
  -from [get_cells -hierarchical -filter {full_name =~ *u_wp/snap_q_reg*}] \
  -to [get_cells -hierarchical -filter {full_name =~ *u_wp/q_reg*}]
set_min_delay 0 \
  -from [get_cells -hierarchical -filter {full_name =~ *u_wp/snap_q_reg*}] \
  -to [get_cells -hierarchical -filter {full_name =~ *u_wp/q_reg*}]
