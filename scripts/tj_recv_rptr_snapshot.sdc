# RECV RPTR snapshot constraints for Synopsys SDC.
# Source after defining clocks and TJ_RECV_MAXI_PERIOD in ns.
set_false_path -to [get_cells -hierarchical -filter {full_name =~ *u_rptr/u_req/meta_q_reg*}]
set_false_path -to [get_cells -hierarchical -filter {full_name =~ *u_rptr/u_ack/meta_q_reg*}]
set_max_delay $TJ_RECV_MAXI_PERIOD \
  -from [get_cells -hierarchical -filter {full_name =~ *u_rptr/snap_q_reg*}] \
  -to [get_cells -hierarchical -filter {full_name =~ *u_rptr/q_reg*}]
set_min_delay 0 \
  -from [get_cells -hierarchical -filter {full_name =~ *u_rptr/snap_q_reg*}] \
  -to [get_cells -hierarchical -filter {full_name =~ *u_rptr/q_reg*}]
