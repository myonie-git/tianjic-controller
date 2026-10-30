# Timestamp snapshot constraints for Vivado.
# Source after defining clocks and TJ_TS_PCLK_PERIOD in ns.
set_false_path -to [get_cells -hier -filter {NAME =~ *u_ts_rd_syn/u_req/meta_q_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_ts_rd_syn/u_ack/meta_q_reg*}]
set_max_delay $TJ_TS_PCLK_PERIOD -datapath_only \
  -from [get_cells -hier -filter {NAME =~ *u_ts_rd_syn/snap_q_reg*}] \
  -to [get_cells -hier -filter {NAME =~ *u_ts_rd_syn/q_reg*}]
