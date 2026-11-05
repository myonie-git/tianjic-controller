# RECV RPTR snapshot constraints for Quartus TimeQuest.
# Source after defining clocks and TJ_RECV_MAXI_PERIOD in ns.
set_false_path -to [get_keepers {*u_rptr|u_req*|meta_q*}]
set_false_path -to [get_keepers {*u_rptr|u_ack*|meta_q*}]
set_max_delay -from [get_keepers {*u_rptr|snap_q*}] \
              -to [get_keepers {*u_rptr|q*}] $TJ_RECV_MAXI_PERIOD
# TODO(RECV-002): Check the hold constraint against the snapshot handshake.
# Signoff uses the 0 ns minimum; fitting can request a larger margin.
set tj_rptr_min_delay 0
if {[info exists TJ_RECV_RPTR_FIT_HOLD_MARGIN]} {
    set tj_rptr_min_delay $TJ_RECV_RPTR_FIT_HOLD_MARGIN
}
set_min_delay -from [get_keepers {*u_rptr|snap_q*}] \
              -to [get_keepers {*u_rptr|q*}] $tj_rptr_min_delay
unset tj_rptr_min_delay
set_max_skew -get_skew_value_from_clock_period min_clock_period -skew_value_multiplier 1.0 \
  -from [get_keepers {*u_rptr|snap_q*}] -to [get_keepers {*u_rptr|q*}]
set_net_delay -max -get_value_from_clock_period dst_clock_period -value_multiplier 1.0 \
  -from [get_keepers {*u_rptr|snap_q*}] -to [get_keepers {*u_rptr|q*}]
