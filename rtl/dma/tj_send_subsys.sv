// File        : tj_send_subsys.sv
// Module      : tj_send_subsys
// Description : Connect CSR controls, record fetch and LVDS packet dispatch.
//               pclk: CSR; maxi_clk: memory reads and packet output.
module tj_send_subsys
  import tj_ctrl_pkg::*;
#(
  parameter int unsigned N_CH    = N_CH_V1,
  parameter int unsigned N_PORTS = ((N_CH + 2) / 3) * N_LVDS_PORTS,
  parameter int unsigned AW      = 40
)(
  // CSR control and status (pclk).
  input  logic                     pclk,
  input  logic                     presetn,
  input  logic                     db_go,          // Start pulse.
  input  logic                     glb_srst,       // Abort pulse.
  input  logic [31:0]              csr_src_lo,
  input  logic [15:0]              csr_src_hi,
  input  logic [31:0]              csr_cnt,
  input  logic [11:0]              csr_lnk_en,
  input  logic [31:0]              csr_remap0,
  input  logic [15:0]              csr_remap1,
  output logic                     sta_busy,       // Startup, transfer or event delivery busy.
  output logic                     sta_done_set,   // Completion event.
  output logic                     sta_err_set,    // Fetch or record error.
  output logic                     irq_send_set,   // IRQ.RAW[9]: completion or record IRQ.
  output logic                     irq_axi_err_set,// IRQ.RAW[28]: AXI read error.
  output logic [31:0]              sta_sent,       // SEND.SENT.
  // Data-path clock and reset.
  input  logic                     maxi_clk,
  input  logic                     maxi_rstn,
  // Memory read interface to tj_axi_rd_backend.
  output logic                     req_valid,
  input  logic                     req_ready,
  output logic [AW-1:0]            req_addr,
  output logic [7:0]               req_len,
  input  logic                     rsp_valid,
  output logic                     rsp_ready,
  input  logic [127:0]             rsp_data,
  input  logic                     rsp_last,
  input  logic                     rsp_err,
  // LVDS packet outputs.
  output logic [N_PORTS-1:0]       tx_tvalid,
  input  logic [N_PORTS-1:0]       tx_tready,
  output logic [N_PORTS-1:0][95:0] tx_tdata
);
  // Control pulses to maxi_clk.
  logic go_maxi, srst_maxi;
  tj_pulse_sync u_go_sync (
    .sclk(pclk), .srst_n(presetn), .pulse_i(db_go),
    .dclk(maxi_clk), .drst_n(maxi_rstn), .pulse_o(go_maxi)
  );
  tj_pulse_sync u_srst_sync (
    .sclk(pclk), .srst_n(presetn), .pulse_i(glb_srst),
    .dclk(maxi_clk), .drst_n(maxi_rstn), .pulse_o(srst_maxi)
  );

  // Program configuration before GO; keep it unchanged until the task ends.
  logic [47:0] src_syn;
  logic [31:0] cnt_syn;
  logic [11:0] en_syn;
  logic [31:0] rm0_syn;
  logic [15:0] rm1_syn;
  tj_sync2 #(.W(48)) u_src_syn (.clk(maxi_clk), .rst_n(maxi_rstn), .d({csr_src_hi, csr_src_lo}), .q(src_syn));
  tj_sync2 #(.W(32)) u_cnt_syn (.clk(maxi_clk), .rst_n(maxi_rstn), .d(csr_cnt),    .q(cnt_syn));
  tj_sync2 #(.W(12)) u_en_syn  (.clk(maxi_clk), .rst_n(maxi_rstn), .d(csr_lnk_en), .q(en_syn));
  tj_sync2 #(.W(32)) u_rm0_syn (.clk(maxi_clk), .rst_n(maxi_rstn), .d(csr_remap0), .q(rm0_syn));
  tj_sync2 #(.W(16)) u_rm1_syn (.clk(maxi_clk), .rst_n(maxi_rstn), .d(csr_remap1), .q(rm1_syn));

  // Ignore start requests while busy.
  logic busy_maxi;
  logic go_gated;
  logic cfg_capture_q, go_q, go_start;
  assign go_gated = go_maxi && !busy_maxi && !srst_maxi;

  logic [47:0] src_frz_q;
  logic [31:0] cnt_frz_q;
  logic [11:0] en_frz_q;
  logic [31:0] rm0_frz_q;
  logic [15:0] rm1_frz_q;
  always_ff @(posedge maxi_clk or negedge maxi_rstn)
    if (!maxi_rstn) begin
      src_frz_q <= '0; cnt_frz_q <= '0; en_frz_q <= '0;
      rm0_frz_q <= 32'h7654_3210; rm1_frz_q <= 16'hBA98;
    end else if (cfg_capture_q && !srst_maxi) begin
      src_frz_q <= src_syn; cnt_frz_q <= cnt_syn; en_frz_q <= en_syn;
      rm0_frz_q <= rm0_syn; rm1_frz_q <= rm1_syn;
    end

  // Allow one extra cycle for configuration synchronization before capture.
  always_ff @(posedge maxi_clk or negedge maxi_rstn)
    if (!maxi_rstn) begin
      cfg_capture_q <= 1'b0;
      go_q          <= 1'b0;
    end else if (srst_maxi) begin
      cfg_capture_q <= 1'b0;
      go_q          <= 1'b0;
    end else begin
      cfg_capture_q <= go_gated;
      go_q          <= cfg_capture_q;
    end

  assign go_start = go_q && !srst_maxi;

  // Record fetch and dispatch (maxi_clk).
  logic     src_done_w, src_err_w, fetch_busy_w;
  logic     rec_valid_w, rec_ready_w;
  tj_rec_t  rec_w;
  logic     eng_busy_w, done_p_w, errrec_p_w, irq_p_w;
  logic [31:0] sent_w;

  tj_send_fetch #(.AW(AW)) u_fetch (
    .clk(maxi_clk), .rst_n(maxi_rstn),
    .go(go_start), .abort(srst_maxi), .cfg_src(src_frz_q), .cfg_cnt(cnt_frz_q),
    .src_done(src_done_w), .src_err(src_err_w), .fetch_busy(fetch_busy_w),
    .req_valid(req_valid), .req_ready(req_ready),
    .req_addr(req_addr), .req_len(req_len),
    .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
    .rsp_data(rsp_data), .rsp_last(rsp_last), .rsp_err(rsp_err),
    .rec_valid(rec_valid_w), .rec_ready(rec_ready_w), .rec(rec_w)
  );

  tj_send_engine #(.N_CH(N_CH), .N_PORTS(N_PORTS)) u_engine (
    .clk(maxi_clk), .rst_n(maxi_rstn),
    .go(go_start), .abort(srst_maxi),
    .cfg_lnk_en(en_frz_q), .cfg_remap0(rm0_frz_q), .cfg_remap1(rm1_frz_q),
    .busy(eng_busy_w), .done_pulse(done_p_w), .err_pulse(errrec_p_w),
    .irq_pulse(irq_p_w), .sent(sent_w),
    .rec_valid(rec_valid_w), .rec_ready(rec_ready_w), .rec(rec_w),
    .src_done(src_done_w),
    .tx_tvalid(tx_tvalid), .tx_tready(tx_tready), .tx_tdata(tx_tdata)
  );

  // Status and events to pclk.
  // Events [2:0]: AXI error, record IRQ, combined error.
  logic [2:0] evt_w;
  logic [2:0] evt_lvl_q, evt_pend_q;
  logic [2:0] evt_lvl_pclk, evt_ack_syn;
  assign evt_w = {src_err_w, irq_p_w, errrec_p_w || src_err_w};

  tj_sync2 #(.W(3)) u_evt_sync (
    .clk(pclk), .rst_n(presetn), .d(evt_lvl_q), .q(evt_lvl_pclk)
  );
  tj_sync2 #(.W(3)) u_evt_ack_sync (
    .clk(maxi_clk), .rst_n(maxi_rstn), .d(evt_lvl_pclk), .q(evt_ack_syn)
  );

  always_ff @(posedge maxi_clk or negedge maxi_rstn)
    if (!maxi_rstn) begin
      evt_lvl_q  <= '0;
      evt_pend_q <= '0;
    end else if (go_start) begin
      evt_lvl_q  <= '0;
      evt_pend_q <= '0;
    end else begin
      for (int i = 0; i < 3; i++)
        if (!evt_lvl_q[i] && (evt_pend_q[i] || evt_w[i])) begin
          if (!evt_ack_syn[i]) begin
            evt_lvl_q[i]  <= 1'b1;
            evt_pend_q[i] <= 1'b0;
          end else begin
            evt_pend_q[i] <= 1'b1;
          end
        end
    end

  logic evt_pending_w;
  assign evt_pending_w = (|evt_pend_q) || (|(evt_lvl_q & ~evt_ack_syn));
  assign busy_maxi = cfg_capture_q || go_q
                     || eng_busy_w || fetch_busy_w || evt_pending_w;

  // Register status before crossing to pclk.
  logic busy_maxi_q;
  always_ff @(posedge maxi_clk or negedge maxi_rstn)
    if (!maxi_rstn) busy_maxi_q <= 1'b0;
    else            busy_maxi_q <= busy_maxi;
  tj_sync2 #(.W(1)) u_busy_syn (
    .clk(pclk), .rst_n(presetn), .d(busy_maxi_q), .q(sta_busy)
  );
  tj_snap_sync #(.W(32)) u_sent_syn (
    .sclk(maxi_clk), .srst_n(maxi_rstn), .d(sent_w),
    .dclk(pclk), .drst_n(presetn), .q(sta_sent)
  );

  logic [2:0] evt_lvl_d_q, evt_rise_w;
  always_ff @(posedge pclk or negedge presetn)
    if (!presetn) evt_lvl_d_q <= '0;
    else          evt_lvl_d_q <= evt_lvl_pclk;
  assign evt_rise_w = evt_lvl_pclk & ~evt_lvl_d_q;

  logic done_pclk;
  tj_pulse_sync u_done_sync (.sclk(maxi_clk), .srst_n(maxi_rstn), .pulse_i(done_p_w),
                             .dclk(pclk), .drst_n(presetn), .pulse_o(done_pclk));

  logic done_pending_q, done_release_w;
  always_ff @(posedge pclk or negedge presetn)
    if (!presetn)       done_pending_q <= 1'b0;
    else if (done_pclk) done_pending_q <= 1'b1;
    else if (!sta_busy) done_pending_q <= 1'b0;
  assign done_release_w = done_pending_q && !sta_busy;

  assign sta_done_set    = done_release_w;
  assign sta_err_set     = evt_rise_w[0];
  assign irq_send_set    = done_release_w | evt_rise_w[1];
  assign irq_axi_err_set = evt_rise_w[2];

endmodule
