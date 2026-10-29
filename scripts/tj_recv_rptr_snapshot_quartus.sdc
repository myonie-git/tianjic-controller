# RECV RPTR snapshot constraints for Quartus TimeQuest.
# Source after defining clocks and TJ_RECV_MAXI_PERIOD in ns.
set_false_path -to [get_keepers {*u_rptr|u_req*|meta_q*}]
set_false_path -to [get_keepers {*u_rptr|u_ack*|meta_q*}]
set_max_delay -from [get_keepers {*u_rptr|snap_q*}] \
              -to [get_keepers {*u_rptr|q*}] $TJ_RECV_MAXI_PERIOD
set_min_delay -from [get_keepers {*u_rptr|snap_q*}] \
              -to [get_keepers {*u_rptr|q*}] 0
set_max_skew -get_skew_value_from_clock_period min_clock_period -skew_value_multiplier 1.0 \
  -from [get_keepers {*u_rptr|snap_q*}] -to [get_keepers {*u_rptr|q*}]
set_net_delay -max -get_value_from_clock_period dst_clock_period -value_multiplier 1.0 \
  -from [get_keepers {*u_rptr|snap_q*}] -to [get_keepers {*u_rptr|q*}]
