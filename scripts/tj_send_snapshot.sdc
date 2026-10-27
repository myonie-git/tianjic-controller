# SEND count snapshot constraints for Synopsys SDC.
# Source after defining clocks and TJ_SEND_PCLK_PERIOD in ns.
set_false_path -to [get_cells -hierarchical -filter {full_name =~ *u_sent_syn/u_req/meta_q_reg*}]
set_false_path -to [get_cells -hierarchical -filter {full_name =~ *u_sent_syn/u_ack/meta_q_reg*}]
set_max_delay $TJ_SEND_PCLK_PERIOD \
  -from [get_cells -hierarchical -filter {full_name =~ *u_sent_syn/snap_q_reg*}] \
  -to [get_cells -hierarchical -filter {full_name =~ *u_sent_syn/q_reg*}]
set_min_delay 0 \
  -from [get_cells -hierarchical -filter {full_name =~ *u_sent_syn/snap_q_reg*}] \
  -to [get_cells -hierarchical -filter {full_name =~ *u_sent_syn/q_reg*}]
