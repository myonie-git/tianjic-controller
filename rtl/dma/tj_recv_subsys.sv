// File        : tj_recv_subsys.sv
// Module      : tj_recv_subsys
// Description : Connect CSR controls, packet reception and ring write status.
// pclk: CSR; maxi_clk: receive and memory write interfaces.
module tj_recv_subsys
  import tj_ctrl_pkg::*;
#(
  parameter int unsigned N_CH    = N_CH_V1,
  parameter int unsigned N_PORTS = ((N_CH + 2) / 3) * N_LVDS_PORTS,
  parameter int unsigned AW      = 40
)(
  // CSR configuration, status and events (pclk).
  input  logic                     pclk,
  input  logic                     presetn,
  input  logic                     glb_srst,  // Soft-abort pulse.
  input  logic [N_CH-1:0][31:0]    csr_ring_lo,
  input  logic [N_CH-1:0][15:0]    csr_ring_hi,
  input  logic [N_CH-1:0][31:0]    csr_size,
  input  logic [N_CH-1:0][31:0]    csr_wmark,
  input  logic [N_CH-1:0]          csr_en,
  input  logic [N_CH-1:0]          csr_pol,
  input  logic [31:0]              csr_remap0,
  input  logic [15:0]              csr_remap1,
  input  logic [N_CH-1:0][31:0]    csr_rptr,
  output logic [N_CH-1:0][31:0]    sta_wptr,
  output logic [N_CH-1:0][15:0]    sta_level,
  output logic [N_CH-1:0]          sta_idle,
  output logic [N_CH-1:0]          set_wmark,  // Watermark event.
  output logic [N_CH-1:0]          set_end,  // END event.
  output logic [N_CH-1:0]          set_ovf,  // Dropped-packet event.
  output logic                     set_axi_werr,  // AXI write error; IRQ.RAW[28].
  // Data-path clock and timestamp.
  input  logic                     maxi_clk,
  input  logic                     maxi_rstn,
  input  logic [47:0]              ts,
  // LVDS receive ports (maxi_clk).
  input  logic [N_PORTS-1:0]       rx_tvalid,
  output logic [N_PORTS-1:0]       rx_tready,
  input  logic [N_PORTS-1:0][95:0] rx_tdata,
  // Record write interface to tj_axi_wr_backend.
  output logic                     wr_valid,
  input  logic                     wr_ready,
  output logic [AW-1:0]            wr_addr,
  output logic [127:0]             wr_data,
  input  logic                     wr_done,
  input  logic                     wr_idle,
  input  logic                     wr_err
);

  // Control and configuration to maxi_clk.

  logic srst_maxi;
  tj_pulse_sync u_srst_sync (
    .sclk(pclk), .srst_n(presetn), .pulse_i(glb_srst),
    .dclk(maxi_clk), .drst_n(maxi_rstn), .pulse_o(srst_maxi)
  );

  logic [N_CH-1:0][47:0] base_syn;
  logic [N_CH-1:0][31:0] size_syn, wmark_syn, rptr_syn;
  logic [N_CH-1:0]       en_syn, pol_syn;
  for (genvar c = 0; c < N_CH; c++) begin : g_cfg_syn
    tj_sync2 #(.W(48)) u_base (.clk(maxi_clk), .rst_n(maxi_rstn),
                               .d({csr_ring_hi[c], csr_ring_lo[c]}), .q(base_syn[c]));
    tj_sync2 #(.W(32)) u_size (.clk(maxi_clk), .rst_n(maxi_rstn), .d(csr_size[c]),  .q(size_syn[c]));
    tj_sync2 #(.W(32)) u_wmk  (.clk(maxi_clk), .rst_n(maxi_rstn), .d(csr_wmark[c]), .q(wmark_syn[c]));
    tj_sync2 #(.W(1))  u_en   (.clk(maxi_clk), .rst_n(maxi_rstn), .d(csr_en[c]),    .q(en_syn[c]));
    tj_sync2 #(.W(1))  u_pol  (.clk(maxi_clk), .rst_n(maxi_rstn), .d(csr_pol[c]),   .q(pol_syn[c]));
    // Transfer host progress as a coherent snapshot.
    tj_snap_sync #(.W(32)) u_rptr (
      .sclk(pclk), .srst_n(presetn), .d(csr_rptr[c]),
      .dclk(maxi_clk), .drst_n(maxi_rstn), .q(rptr_syn[c])
    );
  end

  // Delay enable assertion by two cycles; deassertion follows en_syn.
  logic [N_CH-1:0] en_d1_q, en_d2_q, en_eff;
  always_ff @(posedge maxi_clk or negedge maxi_rstn)
    if (!maxi_rstn) begin
      en_d1_q <= '0;
      en_d2_q <= '0;
    end else begin
      en_d1_q <= en_syn;
      en_d2_q <= en_d1_q;
    end
  assign en_eff = en_syn & en_d1_q & en_d2_q;

  // Keep remapping stable while receiving.
  logic [31:0] remap0_syn;
  logic [15:0] remap1_syn;
  tj_sync2 #(.W(32)) u_remap0 (
    .clk(maxi_clk), .rst_n(maxi_rstn),
    .d(csr_remap0), .q(remap0_syn)
  );
  tj_sync2 #(.W(16)) u_remap1 (
    .clk(maxi_clk), .rst_n(maxi_rstn),
    .d(csr_remap1), .q(remap1_syn)
  );

  // Receive engine.

  logic [N_CH-1:0][31:0] wptr_w;
  logic [N_CH-1:0]       evw_w, eve_w, evo_w, idle_w;

  tj_recv_engine #(.N_CH(N_CH), .N_PORTS(N_PORTS), .AW(AW)) u_engine (
    .clk(maxi_clk), .rst_n(maxi_rstn), .abort(srst_maxi), .ts(ts),
    .cfg_base(base_syn), .cfg_size(size_syn), .cfg_wmark(wmark_syn),
    .cfg_en(en_eff), .cfg_pol(pol_syn), .rptr(rptr_syn),
    .cfg_remap0(remap0_syn), .cfg_remap1(remap1_syn),
    .wptr(wptr_w), .level(), .idle(idle_w),
    .evt_wmark(evw_w), .evt_end(eve_w), .evt_ovf(evo_w),
    .rx_tvalid, .rx_tready, .rx_tdata,
    .wr_valid, .wr_ready, .wr_addr, .wr_data, .wr_done, .wr_idle
  );

  // WPTR snapshots and ring occupancy in pclk.

  for (genvar c = 0; c < N_CH; c++) begin : g_sta_syn
    logic [32:0] snap_w;
    logic upd_w;
    tj_snap_sync #(.W(33)) u_wp (
      .sclk(maxi_clk), .srst_n(maxi_rstn), .d({idle_w[c], wptr_w[c]}),
      .dclk(pclk), .drst_n(presetn), .q(snap_w), .upd(upd_w)
    );
    assign sta_wptr[c] = snap_w[31:0];

    // Discard snapshots that may predate the latest disable request.
    logic [1:0] fresh_q;
    always_ff @(posedge pclk or negedge presetn)
      if (!presetn) fresh_q <= '0;
      else if (csr_en[c]) fresh_q <= '0;
      else if (upd_w && fresh_q != 2'd3) fresh_q <= fresh_q + 2'd1;
    assign sta_idle[c] = snap_w[32] && !csr_en[c] && (fresh_q == 2'd3);
    assign sta_level[c] = 16'(sta_wptr[c] - csr_rptr[c]);
  end

  tj_evt_sync #(.W(3*N_CH + 1)) u_evt (
    .sclk(maxi_clk), .srst_n(maxi_rstn),
    .evt_i({wr_err, evo_w, eve_w, evw_w}),
    .dclk(pclk), .drst_n(presetn),
    .set_o({set_axi_werr, set_ovf, set_end, set_wmark})
  );

endmodule
