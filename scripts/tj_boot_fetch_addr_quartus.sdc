# Set TJ_BOOT_MAXI_PERIOD to the destination period in ns after defining clocks.
# Only the first request synchronizer stage samples the asynchronous toggle.
set_false_path -from [get_keepers {*u_boot*|*u_engine*|f_req_tgl}] \
               -to   [get_keepers {*u_boot*|*u_fetch*|req_syn_q[0]}]

set tj_boot_addr_src [get_keepers {*u_boot*|*u_engine*|f_blk_addr*}]
set tj_boot_addr_dst [get_keepers {*u_boot*|*u_fetch*|addr_q*}]
set_max_delay -from $tj_boot_addr_src -to $tj_boot_addr_dst $TJ_BOOT_MAXI_PERIOD
# Optional extra hold margin for fitting. Leave unset for signoff.
if {[info exists TJ_BOOT_FIT_HOLD_MARGIN]} {
    set_min_delay -from $tj_boot_addr_src -to $tj_boot_addr_dst $TJ_BOOT_FIT_HOLD_MARGIN
}
unset tj_boot_addr_src tj_boot_addr_dst
