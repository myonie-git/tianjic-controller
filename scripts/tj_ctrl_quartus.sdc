# Common CDC paths in tj_ctrl_top for Quartus TimeQuest.
# Load with the five per-path constraints listed in the Controller README.

# Only the first stage receives asynchronous data.
set_false_path -to [get_keepers {*|meta_q*}]

# Bound SEND configuration before GO captures it in maxi_clk.
foreach tj_send_sync {u_src_syn u_cnt_syn u_en_syn u_rm0_syn u_rm1_syn} {
    set_data_delay -from [get_clocks pclk] \
        -to [get_registers "*u_send*|*${tj_send_sync}*|meta_q*"] \
        -get_value_from_clock_period dst_clock_period -value_multiplier 1.0
}
unset tj_send_sync

set_false_path -from [get_keepers {*|tgl_q*}] -to [get_keepers {*|syn_q[0]}]
set_false_path -from [get_keepers {*|tgl_q*}] -to [get_keepers {*|s0_q*}]
set_false_path -from [get_keepers {*u_boot*|*u_fetch*|ack_tgl}] \
               -to   [get_keepers {*u_boot*|*u_engine*|ack_s1_q}]

# The BOOT engine samples the returned block and error after the synchronized ACK.
set tj_boot_return_src [get_registers {*u_boot*|*u_fetch*|blk*}]
set tj_boot_return_dst [get_registers {*u_boot*|*u_engine*|*}]
set_max_delay -from $tj_boot_return_src -to $tj_boot_return_dst $TJ_BOOT_PCLK_PERIOD
set_min_delay -from $tj_boot_return_src -to $tj_boot_return_dst 0
unset tj_boot_return_src tj_boot_return_dst
