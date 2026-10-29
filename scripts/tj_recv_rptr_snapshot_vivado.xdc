# RECV RPTR snapshot constraints for Vivado.
# Source after defining clocks and TJ_RECV_MAXI_PERIOD in ns.
set_false_path -to [get_cells -hier -filter {NAME =~ *u_rptr/u_req/meta_q_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_rptr/u_ack/meta_q_reg*}]
set_max_delay $TJ_RECV_MAXI_PERIOD -datapath_only \
  -from [get_cells -hier -filter {NAME =~ *u_rptr/snap_q_reg*}] \
  -to [get_cells -hier -filter {NAME =~ *u_rptr/q_reg*}]
