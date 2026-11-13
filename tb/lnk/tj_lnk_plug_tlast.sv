// Link-test-only adapter. The chip co-simulation adapter stays unchanged.
module tj_lnk_plug_tlast (
  input  logic [1:0]        core_id,  // Configuration-chain instance ID.
  output logic [1:0]        core_id_next,  // ID for the next instance.
  input  logic              apb_pclk,  // Configuration clock.
  input  logic              axis_brg_clk,  // Packet-interface clock.
  input  logic              lvds_tx_bclk,  // Transmit bit clock.
  input  logic              rstn_raw,

  // Four logical AXIS packet ports.
  input  logic [3:0]        s_tvalid,
  input  logic [3:0]        s_tlast,
  output int unsigned      checked_records, checked_groups,
  output logic [3:0]        s_tready,
  input  logic [3:0][95:0]  s_tdata,
  output logic [3:0]        m_tvalid,
  input  logic [3:0]        m_tready,
  output logic [3:0][95:0]  m_tdata,
  // Upstream configuration chain.
  input  logic [32:0]       cfg_din,
  input  logic              cfg_din_vld,
  output logic [31:0]       cfg_dout,
  output logic              cfg_dout_vld,

  // Downstream configuration chain.
  output logic [32:0]       cfg_din_next,
  output logic              cfg_din_next_vld,
  input  logic [31:0]       cfg_dout_next,
  input  logic              cfg_dout_next_vld,
  output logic              err_intr,
  output logic              send_mode,

  // Three groups per direction, each with one clock pair and five data pairs.
  inout  wire [2:0]         txc_p, txc_n,
  inout  wire [2:0][4:0]    txd_p, txd_n,
  inout  wire [2:0]         rxc_p, rxc_n,
  inout  wire [2:0][4:0]    rxd_p, rxd_n
);
  lvds_subsys #(.USE_EXTERNAL_TLAST(1'b1)) u_lvds (
    .CORE_ID(core_id), .CORE_ID_NEXT(core_id_next),
    .apb_pclk(apb_pclk),
    .dout_pre(cfg_dout), .dout_pre_vld(cfg_dout_vld),
    .din_pre(cfg_din), .din_pre_vld(cfg_din_vld),
    .dout_next(cfg_dout_next), .dout_next_vld(cfg_dout_next_vld),
    .din_next(cfg_din_next), .din_next_vld(cfg_din_next_vld),
    .lvds_err_intr(err_intr), .o_send_mode(send_mode),
    .axis_brg_clk(axis_brg_clk), .lvds_tx_bclk(lvds_tx_bclk),
    .scan_mode(1'b0), .rstn_raw(rstn_raw),
    .m0_axis_tdata(m_tdata[0]), .m0_axis_tvalid(m_tvalid[0]), .m0_axis_tready(m_tready[0]),
    .m1_axis_tdata(m_tdata[1]), .m1_axis_tvalid(m_tvalid[1]), .m1_axis_tready(m_tready[1]),
    .m2_axis_tdata(m_tdata[2]), .m2_axis_tvalid(m_tvalid[2]), .m2_axis_tready(m_tready[2]),
    .m3_axis_tdata(m_tdata[3]), .m3_axis_tvalid(m_tvalid[3]), .m3_axis_tready(m_tready[3]),
    .s0_axis_tdata(s_tdata[0]), .s0_axis_tvalid(s_tvalid[0]), .s0_axis_tready(s_tready[0]), .s0_axis_tlast(s_tlast[0]),
    .s1_axis_tdata(s_tdata[1]), .s1_axis_tvalid(s_tvalid[1]), .s1_axis_tready(s_tready[1]), .s1_axis_tlast(s_tlast[1]),
    .s2_axis_tdata(s_tdata[2]), .s2_axis_tvalid(s_tvalid[2]), .s2_axis_tready(s_tready[2]), .s2_axis_tlast(s_tlast[2]),
    .s3_axis_tdata(s_tdata[3]), .s3_axis_tvalid(s_tvalid[3]), .s3_axis_tready(s_tready[3]), .s3_axis_tlast(s_tlast[3]),
    .TX0_LVDS_CLK_P(txc_p[0]), .TX0_LVDS_CLK_N(txc_n[0]),
    .TX0_LVDS_DAT0_P(txd_p[0][0]), .TX0_LVDS_DAT0_N(txd_n[0][0]),
    .TX0_LVDS_DAT1_P(txd_p[0][1]), .TX0_LVDS_DAT1_N(txd_n[0][1]),
    .TX0_LVDS_DAT2_P(txd_p[0][2]), .TX0_LVDS_DAT2_N(txd_n[0][2]),
    .TX0_LVDS_DAT3_P(txd_p[0][3]), .TX0_LVDS_DAT3_N(txd_n[0][3]),
    .TX0_LVDS_DAT4_P(txd_p[0][4]), .TX0_LVDS_DAT4_N(txd_n[0][4]),
    .TX1_LVDS_CLK_P(txc_p[1]), .TX1_LVDS_CLK_N(txc_n[1]),
    .TX1_LVDS_DAT0_P(txd_p[1][0]), .TX1_LVDS_DAT0_N(txd_n[1][0]),
    .TX1_LVDS_DAT1_P(txd_p[1][1]), .TX1_LVDS_DAT1_N(txd_n[1][1]),
    .TX1_LVDS_DAT2_P(txd_p[1][2]), .TX1_LVDS_DAT2_N(txd_n[1][2]),
    .TX1_LVDS_DAT3_P(txd_p[1][3]), .TX1_LVDS_DAT3_N(txd_n[1][3]),
    .TX1_LVDS_DAT4_P(txd_p[1][4]), .TX1_LVDS_DAT4_N(txd_n[1][4]),
    .TX2_LVDS_CLK_P(txc_p[2]), .TX2_LVDS_CLK_N(txc_n[2]),
    .TX2_LVDS_DAT0_P(txd_p[2][0]), .TX2_LVDS_DAT0_N(txd_n[2][0]),
    .TX2_LVDS_DAT1_P(txd_p[2][1]), .TX2_LVDS_DAT1_N(txd_n[2][1]),
    .TX2_LVDS_DAT2_P(txd_p[2][2]), .TX2_LVDS_DAT2_N(txd_n[2][2]),
    .TX2_LVDS_DAT3_P(txd_p[2][3]), .TX2_LVDS_DAT3_N(txd_n[2][3]),
    .TX2_LVDS_DAT4_P(txd_p[2][4]), .TX2_LVDS_DAT4_N(txd_n[2][4]),
    .RX0_LVDS_CLK_P(rxc_p[0]), .RX0_LVDS_CLK_N(rxc_n[0]),
    .RX0_LVDS_DAT0_P(rxd_p[0][0]), .RX0_LVDS_DAT0_N(rxd_n[0][0]),
    .RX0_LVDS_DAT1_P(rxd_p[0][1]), .RX0_LVDS_DAT1_N(rxd_n[0][1]),
    .RX0_LVDS_DAT2_P(rxd_p[0][2]), .RX0_LVDS_DAT2_N(rxd_n[0][2]),
    .RX0_LVDS_DAT3_P(rxd_p[0][3]), .RX0_LVDS_DAT3_N(rxd_n[0][3]),
    .RX0_LVDS_DAT4_P(rxd_p[0][4]), .RX0_LVDS_DAT4_N(rxd_n[0][4]),
    .RX1_LVDS_CLK_P(rxc_p[1]), .RX1_LVDS_CLK_N(rxc_n[1]),
    .RX1_LVDS_DAT0_P(rxd_p[1][0]), .RX1_LVDS_DAT0_N(rxd_n[1][0]),
    .RX1_LVDS_DAT1_P(rxd_p[1][1]), .RX1_LVDS_DAT1_N(rxd_n[1][1]),
    .RX1_LVDS_DAT2_P(rxd_p[1][2]), .RX1_LVDS_DAT2_N(rxd_n[1][2]),
    .RX1_LVDS_DAT3_P(rxd_p[1][3]), .RX1_LVDS_DAT3_N(rxd_n[1][3]),
    .RX1_LVDS_DAT4_P(rxd_p[1][4]), .RX1_LVDS_DAT4_N(rxd_n[1][4]),
    .RX2_LVDS_CLK_P(rxc_p[2]), .RX2_LVDS_CLK_N(rxc_n[2]),
    .RX2_LVDS_DAT0_P(rxd_p[2][0]), .RX2_LVDS_DAT0_N(rxd_n[2][0]),
    .RX2_LVDS_DAT1_P(rxd_p[2][1]), .RX2_LVDS_DAT1_N(rxd_n[2][1]),
    .RX2_LVDS_DAT2_P(rxd_p[2][2]), .RX2_LVDS_DAT2_N(rxd_n[2][2]),
    .RX2_LVDS_DAT3_P(rxd_p[2][3]), .RX2_LVDS_DAT3_N(rxd_n[2][3]),
    .RX2_LVDS_DAT4_P(rxd_p[2][4]), .RX2_LVDS_DAT4_N(rxd_n[2][4])
  );
  // Passive observation at the arbiter's AXIS output ports, before PHY packing.
  // Compare TLAST as well as data, so tying TLAST high cannot pass this test.
  typedef struct packed {logic last; logic [95:0] data;} record_t;
  // Test payload bits [55:48] identify a group; groups may overtake on different links.
  record_t expected[4][256][$];
  bit group_active[4][256];
  int group_lane[4][256];
  wire [2:0][95:0] out_data = u_lvds.u_axis_mimo_tx.m_axis_tdata;
  wire [2:0] out_valid = u_lvds.u_axis_mimo_tx.m_axis_tvalid;
  wire [2:0] out_ready = u_lvds.u_axis_mimo_tx.m_axis_tready;
  wire [2:0] out_last = u_lvds.u_axis_mimo_tx.m_axis_tlast;
  always @(posedge axis_brg_clk) begin
    if (!rstn_raw) begin
      checked_records = 0;
      checked_groups = 0;
      for (int p = 0; p < 4; p++) begin
        for (int g = 0; g < 256; g++) begin
          expected[p][g].delete();
          group_active[p][g] = 0;
        end
      end
    end else begin
      for (int p = 0; p < 4; p++)
        if (s_tvalid[p] && s_tready[p])
          expected[p][s_tdata[p][55:48]].push_back({s_tlast[p], s_tdata[p]});
      for (int lane = 0; lane < 3; lane++) begin
        if (out_valid[lane] && out_ready[lane]) begin
          int p, g;
          record_t e;
          p = out_data[lane][5:4];
          g = out_data[lane][55:48];
          if (expected[p][g].size() == 0) $fatal(1, "Unexpected arbiter output port %0d", p);
          e = expected[p][g].pop_front();
          if ({out_last[lane], out_data[lane]} !== e)
            $fatal(1, "Arbiter data/TLAST mismatch port %0d lane %0d: got %h/%b expected %h/%b",
                   p, lane, out_data[lane], out_last[lane], e.data, e.last);
          if (group_active[p][g] && group_lane[p][g] != lane)
            $fatal(1, "AXIS group changed physical lane before TLAST, port %0d", p);
          group_lane[p][g] = lane;
          group_active[p][g] = !out_last[lane];
          checked_records++;
          if (out_last[lane]) checked_groups++;
        end
      end
    end
  end

endmodule
