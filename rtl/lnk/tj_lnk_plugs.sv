// File        : tj_lnk_plugs.sv
// Module      : tj_lnk_plug_ideal, tj_lnk_plug_chip
// Description : Loopback and chip-RTL adapters for LVDS link simulation.

// Combinational loopback; configuration requests have no response.
module tj_lnk_plug_ideal #(
  parameter int unsigned N_PORTS = 4
)(
  input  logic [N_PORTS-1:0]        tx_tvalid,
  output logic [N_PORTS-1:0]        tx_tready,
  input  logic [N_PORTS-1:0][95:0]  tx_tdata,
  output logic [N_PORTS-1:0]        rx_tvalid,
  input  logic [N_PORTS-1:0]        rx_tready,
  output logic [N_PORTS-1:0][95:0]  rx_tdata,
  input  logic [32:0]               cfg_din,
  input  logic                      cfg_din_vld,
  output logic [31:0]               cfg_dout,
  output logic                      cfg_dout_vld
);
  assign rx_tvalid = tx_tvalid;
  assign rx_tdata  = tx_tdata;
  assign tx_tready = rx_tready;
  assign cfg_dout     = '0;
  assign cfg_dout_vld = 1'b0;
endmodule

// Adapt the chip LVDS module to packed packet and differential-I/O arrays.
module tj_lnk_plug_chip (
  input  logic [1:0]        core_id,  // Configuration-chain instance ID.
  output logic [1:0]        core_id_next,  // ID for the next instance.
  input  logic              apb_pclk,  // Configuration clock.
  input  logic              axis_brg_clk,  // Packet-interface clock.
  input  logic              lvds_tx_bclk,  // Transmit bit clock.
  input  logic              rstn_raw,

  // Four logical AXIS packet ports.
  input  logic [3:0]        s_tvalid,
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
  lvds_subsys u_lvds (
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
    .s0_axis_tdata(s_tdata[0]), .s0_axis_tvalid(s_tvalid[0]), .s0_axis_tready(s_tready[0]),
    .s1_axis_tdata(s_tdata[1]), .s1_axis_tvalid(s_tvalid[1]), .s1_axis_tready(s_tready[1]),
    .s2_axis_tdata(s_tdata[2]), .s2_axis_tvalid(s_tvalid[2]), .s2_axis_tready(s_tready[2]),
    .s3_axis_tdata(s_tdata[3]), .s3_axis_tvalid(s_tvalid[3]), .s3_axis_tready(s_tready[3]),
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
endmodule
