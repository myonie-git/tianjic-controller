// File        : tj_ctrl_top.sv
// Module      : tj_ctrl_top
// Description : Connect APB control, SPI, configuration chains and DDR/LVDS data paths.
module tj_ctrl_top
  import tj_ctrl_pkg::*, tj_ctrl_csr_pkg::*;
#(
  // N_CH must match the implemented CSR channel count (currently three).
  parameter int unsigned N_CH        = N_CH_V1,
  parameter int unsigned N_LVDS_INST = (N_CH + 2) / 3, // Three channel groups per instance.
  parameter int unsigned AXI_AW      = 48,
  // The connected data path supports 128-bit AXI beats.
  parameter int unsigned AXI_DW      = 128,
  parameter int unsigned AXI_UW      = 10,  // USER fields are tied to zero.
  parameter int unsigned AXI_IDW     = 4,
  parameter int unsigned APB_AW      = 16   // Matches the CSR address port.
)(

  // pclk: CSR, SPI and configuration chains; maxi_clk: AXI, packets and timestamps.
  input  logic                   pclk,
  // Both active-low resets must assert together.
  input  logic                   presetn,
  input  logic                   maxi_clk,
  input  logic                   maxi_rstn,

  // APB register and SPI window access.
  input  logic                   psel,
  input  logic                   penable,
  input  logic                   pwrite,
  input  logic [APB_AW-1:0]      paddr,
  input  logic [31:0]            pwdata,
  output logic                   pready,
  output logic                   pslverr,
  output logic [31:0]            prdata,

  // AXI4 writes: one 16-byte record per transaction.
  output logic                   awvalid,
  input  logic                   awready,
  output logic [AXI_IDW-1:0]     awid,
  output logic [AXI_AW-1:0]      awaddr,
  output logic [AXI_UW-1:0]      awuser,
  output logic [7:0]             awlen,
  output logic [2:0]             awsize,
  output logic [1:0]             awburst,
  output logic                   wvalid,
  input  logic                   wready,
  output logic [AXI_DW-1:0]      wdata,
  output logic [AXI_DW/8-1:0]    wstrb,
  output logic                   wlast,
  input  logic                   bvalid,
  output logic                   bready,
  input  logic [1:0]             bresp,
  input  logic [AXI_IDW-1:0]     bid,
  // AXI4 reads: 128-bit INCR bursts; SEND table base is 64-byte aligned.
  output logic                   arvalid,
  input  logic                   arready,
  output logic [AXI_IDW-1:0]     arid,
  output logic [AXI_AW-1:0]      araddr,
  output logic [AXI_UW-1:0]      aruser,
  output logic [7:0]             arlen,
  output logic [2:0]             arsize,
  output logic [1:0]             arburst,
  input  logic                   rvalid,
  output logic                   rready,
  input  logic [AXI_DW-1:0]      rdata,
  input  logic [1:0]             rresp,
  input  logic                   rlast,
  input  logic [AXI_IDW-1:0]     rid,

  // Reserved packet stream interfaces.
  input  logic                   s_axis_pk_tvalid,
  output logic                   s_axis_pk_tready,
  input  logic [127:0]           s_axis_pk_tdata,
  input  logic                   s_axis_pk_tlast,
  output logic                   m_axis_pk_tvalid,
  input  logic                   m_axis_pk_tready,
  output logic [127:0]           m_axis_pk_tdata,
  output logic                   m_axis_pk_tlast,

  // Interrupt outputs: completion, receive events, errors and bit31.
  output logic [3:0]             irq,

  // FPGA-side LVDS interfaces: packets in maxi_clk, configuration in pclk.
  output logic [N_LVDS_INST*N_LVDS_PORTS-1:0]        lv_tx_tvalid,
  input  logic [N_LVDS_INST*N_LVDS_PORTS-1:0]        lv_tx_tready,
  output logic [N_LVDS_INST*N_LVDS_PORTS-1:0][95:0]  lv_tx_tdata,
  input  logic [N_LVDS_INST*N_LVDS_PORTS-1:0]        lv_rx_tvalid,
  output logic [N_LVDS_INST*N_LVDS_PORTS-1:0]        lv_rx_tready,
  input  logic [N_LVDS_INST*N_LVDS_PORTS-1:0][95:0]  lv_rx_tdata,
  output logic [N_LVDS_INST-1:0][32:0]               lvcfg_din,
  output logic [N_LVDS_INST-1:0]                     lvcfg_din_vld,
  input  logic [N_LVDS_INST-1:0][31:0]               lvcfg_dout,
  input  logic [N_LVDS_INST-1:0]                     lvcfg_dout_vld,

  // Eight shared SCLK/MOSI groups; one CS_N/MISO per die. Board routing is external.
  output logic [N_SPI_GRP-1:0]   spi_sclk,
  output logic [N_SPI_GRP-1:0]   spi_mosi,
  output logic [N_DIE-1:0]       spi_cs_n,
  input  logic [N_DIE-1:0]       spi_miso,

  // Chip reset and clock-buffer enable levels; board mapping is external.
  output logic [N_RST-1:0]       chip_rst_n,  // Reset value: zero (reset asserted).
  output logic [3:0]             clkctl,      // Reset value: zero; polarity depends on wiring.
  // Reserved UART; TX remains high.
  input  logic                   uart_rx,
  output logic                   uart_tx
);

  // Supported top-level parameter combinations.
  if (N_CH != TJ_CSR_RECV_N) begin : g_nch_guard
    $fatal(1, "N_CH must match the CSR channel count.");
  end
  if (APB_AW != 16) begin : g_apbaw_guard
    $fatal(1, "APB_AW must be 16.");
  end
  if (AXI_AW < 48) begin : g_axiaw_guard
    $fatal(1, "AXI_AW must be at least 48.");
  end

  // CSR inputs and outputs.
  tj_csr_i_t hwi;
  tj_csr_o_t hwo;

  // APB 0x4000..0x4FFF selects SPIWIN; other addresses select CSR.
  wire         win_hit  = (paddr[15:12] == 4'h4);
  wire         psel_csr = psel && !win_hit;
  wire         psel_win = psel && win_hit;
  logic        csr_pready, csr_pslverr, win_pready, win_pslverr;
  logic [31:0] csr_prdata, win_prdata;
  assign pready  = win_hit ? win_pready  : csr_pready;
  assign pslverr = win_hit ? win_pslverr : csr_pslverr;
  assign prdata  = win_hit ? win_prdata  : csr_prdata;

  tj_ctrl_csr u_csr (
    .pclk, .presetn,
    .psel(psel_csr), .penable, .pwrite, .paddr, .pwdata,
    .pready(csr_pready), .pslverr(csr_pslverr), .prdata(csr_prdata),
    .hwi, .hwo
  );

  logic [7:0][31:0] spi_rdata_w;
  logic [7:0]       spi_busy_w, eng_busy_w, spi_done_w, spi_err_w;
  logic             spiwin_busy_w, spiwin_err_w;

  logic [32:0] cc_din_w;
  logic        cc_din_vld_w, cc_busy_w, cc_dvld_w;
  logic [31:0] cc_rdata_w, cc_dout_mux;
  logic        cc_dout_vld_mux;

  logic        send_busy_w, send_done_w, send_err_w, send_irq_w, send_axi_err_w;
  logic [31:0] send_sent_w;
  logic                mrd_req_valid, mrd_req_ready;
  logic [AXI_AW-1:0]   mrd_req_addr;
  logic [7:0]          mrd_req_len;
  logic                mrd_rsp_valid, mrd_rsp_ready, mrd_rsp_last, mrd_rsp_err;
  logic [127:0]        mrd_rsp_data;
  // BOOT status, SPI transactions and memory requests.
  logic        boot_busy_w, boot_done_w, boot_err_w;
  logic [3:0]  boot_code_w;
  logic        bt_cmd_valid_w, bt_cmd_ready_w, bt_wdat_valid_w, bt_wdat_ready_w;
  logic        bt_rdat_valid_w, bt_rdat_ready_w, bt_done_w, bt_err_w;
  logic [4:0]  bt_die_w;
  logic [1:0]  bt_kind_w;
  logic [31:0] bt_addr_w, bt_wdat_w, bt_rdat_w;
  logic                bfm_req_valid, bfm_req_ready;
  logic [AXI_AW-1:0]   bfm_req_addr;
  logic [7:0]          bfm_req_len;
  logic                bfm_rsp_valid, bfm_rsp_ready;
  logic                mm_req_valid, mm_req_ready;
  logic [AXI_AW-1:0]   mm_req_addr;
  logic [7:0]          mm_req_len;
  logic                mm_rsp_valid, mm_rsp_ready;
  logic [127:0]        mux_rsp_data, mrd_rsp_data_bk;
  logic                mux_rsp_last, mux_rsp_err, mrd_rsp_last_bk, mrd_rsp_err_bk;

  logic [N_CH-1:0]       recv_wmark_set_w, recv_end_set_w, recv_ovf_set_w;
  logic                  recv_axi_werr_w;
  logic [N_CH-1:0][31:0] recv_wptr_w;
  logic [N_CH-1:0][15:0] recv_level_w;
  logic                  mwr_valid, mwr_ready, mwr_done, mwr_idle, mwr_err;
  logic [AXI_AW-1:0]     mwr_addr;
  logic [127:0]          mwr_data;

  // SPI engines, doorbells and the blocking window.
  tj_spi_subsys u_spi (
    .pclk, .presetn, .hwo(hwo),
    .spi_rdata_o(spi_rdata_w), .spi_busy_o(spi_busy_w), .eng_busy_o(eng_busy_w),
    .spi_done_set_o(spi_done_w), .spi_err_set_o(spi_err_w),
    .spiwin_busy_o(spiwin_busy_w), .spiwin_err_set_o(spiwin_err_w),
    .bt_cmd_valid(bt_cmd_valid_w), .bt_cmd_ready(bt_cmd_ready_w),
    .bt_die(bt_die_w), .bt_kind(bt_kind_w), .bt_addr(bt_addr_w),
    .bt_wdat_valid(bt_wdat_valid_w), .bt_wdat_ready(bt_wdat_ready_w), .bt_wdat(bt_wdat_w),
    .bt_rdat_valid(bt_rdat_valid_w), .bt_rdat_ready(bt_rdat_ready_w), .bt_rdat(bt_rdat_w),
    .bt_done(bt_done_w), .bt_err(bt_err_w),
    .win_psel(psel_win), .win_penable(penable), .win_pwrite(pwrite),
    .win_paddr(paddr[11:0]), .win_pwdata(pwdata),
    .win_pready(win_pready), .win_pslverr(win_pslverr), .win_prdata(win_prdata),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi),
    .spi_cs_n(spi_cs_n), .spi_miso(spi_miso)
  );

  // BOOT loading through the shared memory and SPI paths.
  tj_boot_subsys u_boot (
    .pclk(pclk), .presetn(presetn), .maxi_clk(maxi_clk), .maxi_rstn(maxi_rstn),
    .db_go(hwo.boot_db_go), .glb_srst(hwo.glb_ctrl_srst),
    .csr_kind(hwo.boot_cmd_kind), .csr_die(hwo.boot_cmd_die),
    .csr_src_lo(hwo.boot_src_lo), .csr_src_hi(hwo.boot_src_hi),
    .csr_len(hwo.boot_len), .csr_dst(hwo.boot_dst),
    .sta_busy(boot_busy_w), .sta_done_set(boot_done_w),
    .sta_err_set(boot_err_w), .sta_err_code(boot_code_w),
    .req_valid(bfm_req_valid), .req_ready(bfm_req_ready),
    .req_addr(bfm_req_addr), .req_len(bfm_req_len),
    .rsp_valid(bfm_rsp_valid), .rsp_ready(bfm_rsp_ready),
    .rsp_data(mux_rsp_data), .rsp_last(mux_rsp_last), .rsp_err(mux_rsp_err),
    .cmd_valid(bt_cmd_valid_w), .cmd_ready(bt_cmd_ready_w),
    .die_id(bt_die_w), .cmd_kind(bt_kind_w), .addr(bt_addr_w),
    .wdat_valid(bt_wdat_valid_w), .wdat_ready(bt_wdat_ready_w), .wdat(bt_wdat_w),
    .rdat_valid(bt_rdat_valid_w), .rdat_ready(bt_rdat_ready_w), .rdat(bt_rdat_w),
    .done(bt_done_w), .err_timeout(bt_err_w)
  );

  // Timestamp counter in maxi_clk; prescalers: /1, /16, /100, /1000.
  logic [47:0] ts_q, ts_pclk_w;
  logic [9:0]  ts_pre_q, ts_pre_max;
  logic        ts_en_m_w, ts_clr_m_w;
  logic [1:0]  ts_presc_m_w;
  tj_sync2 #(.W(3)) u_ts_ctrl_syn (
    .clk(maxi_clk), .rst_n(maxi_rstn),
    .d({hwo.sys_ts_ctrl_en, hwo.sys_ts_ctrl_presc}),
    .q({ts_en_m_w, ts_presc_m_w})
  );
  tj_pulse_sync u_ts_clr_syn (
    .sclk(pclk), .srst_n(presetn), .pulse_i(hwo.sys_ts_ctrl_clr),
    .dclk(maxi_clk), .drst_n(maxi_rstn), .pulse_o(ts_clr_m_w)
  );
  always_comb begin
    unique case (ts_presc_m_w)
      2'd0:    ts_pre_max = 10'd0;
      2'd1:    ts_pre_max = 10'd15;
      2'd2:    ts_pre_max = 10'd99;
      default: ts_pre_max = 10'd999;
    endcase
  end
  always_ff @(posedge maxi_clk or negedge maxi_rstn) begin
    if (!maxi_rstn) begin
      ts_q <= '0; ts_pre_q <= '0;
    end else if (ts_clr_m_w) begin
      ts_q <= '0; ts_pre_q <= '0;
    end else if (ts_en_m_w) begin
      if (ts_pre_q == ts_pre_max) begin
        ts_pre_q <= '0; ts_q <= ts_q + 48'd1;
      end else begin
        ts_pre_q <= ts_pre_q + 10'd1;
      end
    end
  end
  // Coherent snapshot for CSR reads; use HI-LO-HI to read all 48 bits.
  tj_snap_sync #(.W(48)) u_ts_rd_syn (
    .sclk(maxi_clk), .srst_n(maxi_rstn), .d(ts_q),
    .dclk(pclk), .drst_n(presetn), .q(ts_pclk_w)
  );

  // Collect status and events; unconnected functions remain zero.
  always_comb begin
    hwi = '0;
    hwi.sys_ts_lo = ts_pclk_w[31:0];
    hwi.sys_ts_hi = ts_pclk_w[47:32];
    hwi.spi_rdata            = spi_rdata_w;
    hwi.spi_sta_busy         = spi_busy_w;  // Doorbell transaction busy.
    hwi.spi_sta_done_set     = spi_done_w;
    hwi.spi_sta_err_tmo_set  = spi_err_w;
    hwi.spiwin_sta_busy      = spiwin_busy_w;
    hwi.spiwin_sta_err_tmo_set = spiwin_err_w;
    hwi.glb_sta_spi_busy     = eng_busy_w;  // Includes SPIWIN and BOOT activity.
    hwi.cc_rdata             = cc_rdata_w;
    hwi.cc_sta_busy          = cc_busy_w;
    hwi.cc_sta_dvld_set      = cc_dvld_w;
    hwi.glb_sta_cc_busy      = cc_busy_w;
    hwi.send_sta_busy        = send_busy_w;
    hwi.send_sta_done_set    = send_done_w;
    hwi.send_sta_err_set     = send_err_w;
    hwi.send_sent            = send_sent_w;
    hwi.glb_sta_send_busy    = send_busy_w;
    hwi.boot_sta_busy        = boot_busy_w;
    hwi.boot_sta_done_set    = boot_done_w;
    hwi.boot_sta_err_set     = boot_err_w;
    hwi.boot_sta_err_code    = boot_code_w;
    hwi.glb_sta_boot_busy    = boot_busy_w;
    hwi.recv_sta_wmark_hit_set = recv_wmark_set_w;
    hwi.recv_sta_endpkt_set  = recv_end_set_w;
    hwi.recv_sta_ovf_set     = recv_ovf_set_w;
    hwi.recv_sta_level       = recv_level_w;
    hwi.recv_wptr            = recv_wptr_w;

    hwi.irq_raw_set[7:0]     = spi_done_w;
    hwi.irq_raw_set[8]       = boot_done_w;
    hwi.irq_raw_set[9]       = send_irq_w;
    hwi.irq_raw_set[10]      = cc_dvld_w;
    for (int c = 0; c < N_CH; c++)
      hwi.irq_raw_set[12 + c] = (recv_wmark_set_w[c] & hwo.recv_ctrl_ie_wmark[c])
                              | (recv_end_set_w[c]   & hwo.recv_ctrl_ie_end[c]);
    hwi.irq_raw_set[24]      = (|spi_err_w) | spiwin_err_w;
    hwi.irq_raw_set[27]      = |recv_ovf_set_w;
    hwi.irq_raw_set[28]      = send_axi_err_w | recv_axi_werr_w;
    hwi.irq_raw_set[29]      = boot_err_w;
  end

  // Enabled IRQ groups: completion/control, receive, errors, reserved bit31.
  assign irq[0] = |hwo.irq_sta[11:0];
  assign irq[1] = |hwo.irq_sta[23:12];
  assign irq[2] = |hwo.irq_sta[30:24];
  assign irq[3] = hwo.irq_sta[31];

  // Drive the configured pin levels directly.
  assign chip_rst_n = hwo.sys_rst_level[N_RST-1:0];
  assign clkctl     = hwo.sys_clk_ctl;

  // AXI user fields are tied to zero.
  assign aruser  = '0;
  assign awuser  = '0;

  // Reserved streams: discard input and keep output inactive.
  assign s_axis_pk_tready = 1'b1;
  assign m_axis_pk_tvalid = 1'b0;
  assign m_axis_pk_tdata  = '0;
  assign m_axis_pk_tlast  = 1'b0;

  // Receive packets into per-channel DDR rings.
  tj_recv_subsys #(
    .N_CH(N_CH), .N_PORTS(N_LVDS_INST*N_LVDS_PORTS), .AW(AXI_AW)
  ) u_recv (
    .pclk, .presetn,
    .glb_srst   (hwo.glb_ctrl_srst),
    .csr_ring_lo(hwo.recv_ring_lo), .csr_ring_hi(hwo.recv_ring_hi),
    .csr_size   (hwo.recv_size),    .csr_wmark  (hwo.recv_wmark),
    .csr_en     (hwo.recv_ctrl_en), .csr_pol    (hwo.recv_ctrl_ovf_policy),
    .csr_remap0 (hwo.lnk_remap0),   .csr_remap1 (hwo.lnk_remap1),
    .csr_rptr   (hwo.recv_rptr),
    .sta_wptr(recv_wptr_w), .sta_level(recv_level_w),
    .set_wmark(recv_wmark_set_w), .set_end(recv_end_set_w),
    .set_ovf(recv_ovf_set_w), .set_axi_werr(recv_axi_werr_w),
    .maxi_clk, .maxi_rstn, .ts(ts_q),
    .rx_tvalid(lv_rx_tvalid), .rx_tready(lv_rx_tready), .rx_tdata(lv_rx_tdata),
    .wr_valid(mwr_valid), .wr_ready(mwr_ready),
    .wr_addr(mwr_addr), .wr_data(mwr_data),
    .wr_done(mwr_done), .wr_idle(mwr_idle), .wr_err(mwr_err)
  );

  tj_axi_wr_backend #(
    .AW(AXI_AW), .AXI_AW(AXI_AW), .AXI_DW(AXI_DW), .AXI_IDW(AXI_IDW)
  ) u_axi_wr (
    .clk(maxi_clk), .rst_n(maxi_rstn),
    .wr_valid(mwr_valid), .wr_ready(mwr_ready),
    .wr_addr(mwr_addr), .wr_data(mwr_data),
    .wr_err(mwr_err), .wr_done(mwr_done), .wr_idle(mwr_idle),
    .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
    .wvalid, .wready, .wdata, .wstrb, .wlast,
    .bvalid, .bready, .bresp, .bid
  );

  // Fetch and dispatch records; the chip LVDS wrapper requires maxi_clk >= bclk / 4.
  tj_send_subsys #(
    .N_CH(N_CH), .N_PORTS(N_LVDS_INST*N_LVDS_PORTS), .AW(AXI_AW)
  ) u_send (
    .pclk, .presetn,
    .db_go     (hwo.send_db_go),
    .glb_srst  (hwo.glb_ctrl_srst),
    .csr_src_lo(hwo.send_src_lo), .csr_src_hi(hwo.send_src_hi),
    .csr_cnt   (hwo.send_cnt),
    .csr_lnk_en(hwo.lnk_en),
    .csr_remap0(hwo.lnk_remap0), .csr_remap1(hwo.lnk_remap1),
    .sta_busy(send_busy_w), .sta_done_set(send_done_w),
    .sta_err_set(send_err_w), .irq_send_set(send_irq_w),
    .irq_axi_err_set(send_axi_err_w),
    .sta_sent(send_sent_w),
    .maxi_clk, .maxi_rstn,
    .req_valid(mrd_req_valid), .req_ready(mrd_req_ready),
    .req_addr(mrd_req_addr), .req_len(mrd_req_len),
    .rsp_valid(mrd_rsp_valid), .rsp_ready(mrd_rsp_ready),
    .rsp_data(mrd_rsp_data), .rsp_last(mrd_rsp_last), .rsp_err(mrd_rsp_err),
    .tx_tvalid(lv_tx_tvalid), .tx_tready(lv_tx_tready), .tx_tdata(lv_tx_tdata)
  );

  // Shared AXI reads: A=SEND (priority), B=BOOT.
  tj_mem_rd_mux #(.AW(AXI_AW)) u_mrd_mux (
    .clk(maxi_clk), .rst_n(maxi_rstn),
    .a_req_valid(mrd_req_valid), .a_req_ready(mrd_req_ready),
    .a_req_addr(mrd_req_addr), .a_req_len(mrd_req_len),
    .a_rsp_valid(mrd_rsp_valid), .a_rsp_ready(mrd_rsp_ready),
    .b_req_valid(bfm_req_valid), .b_req_ready(bfm_req_ready),
    .b_req_addr(bfm_req_addr), .b_req_len(bfm_req_len),
    .b_rsp_valid(bfm_rsp_valid), .b_rsp_ready(bfm_rsp_ready),
    .m_req_valid(mm_req_valid), .m_req_ready(mm_req_ready),
    .m_req_addr(mm_req_addr), .m_req_len(mm_req_len),
    .m_rsp_valid(mm_rsp_valid), .m_rsp_ready(mm_rsp_ready),
    .m_rsp_data(mrd_rsp_data_bk), .m_rsp_last(mrd_rsp_last_bk), .m_rsp_err(mrd_rsp_err_bk),
    .rsp_data(mux_rsp_data), .rsp_last(mux_rsp_last), .rsp_err(mux_rsp_err)
  );
  assign mrd_rsp_data = mux_rsp_data;
  assign mrd_rsp_last = mux_rsp_last;
  assign mrd_rsp_err  = mux_rsp_err;

  tj_axi_rd_backend #(
    .AW(AXI_AW), .AXI_AW(AXI_AW), .AXI_DW(AXI_DW), .AXI_IDW(AXI_IDW)
  ) u_axi_rd (
    .clk(maxi_clk), .rst_n(maxi_rstn),
    .req_valid(mm_req_valid), .req_ready(mm_req_ready),
    .req_addr(mm_req_addr), .req_len(mm_req_len),
    .rsp_valid(mm_rsp_valid), .rsp_ready(mm_rsp_ready),
    .rsp_data(mrd_rsp_data_bk), .rsp_last(mrd_rsp_last_bk), .rsp_err(mrd_rsp_err_bk),
    .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
    .rvalid, .rready, .rdata, .rresp, .rlast, .rid
  );

  // Select the valid configuration response; instances must not reply simultaneously.
  always_comb begin
    cc_dout_mux     = '0;
    cc_dout_vld_mux = 1'b0;
    for (int i = 0; i < N_LVDS_INST; i++) begin
      if (lvcfg_dout_vld[i]) begin
        cc_dout_mux     = lvcfg_dout[i];
        cc_dout_vld_mux = 1'b1;
      end
    end
  end

  tj_cfgchain_master u_ccm (
    .clk(pclk), .rst_n(presetn),
    .db_go(hwo.cc_db_go), .kind(hwo.cc_cmd_kind), .inst(hwo.cc_cmd_inst),
    .wdata(hwo.cc_wdata),
    .rdata_o(cc_rdata_w), .busy_o(cc_busy_w), .dvld_set_o(cc_dvld_w),
    .din(cc_din_w), .din_vld(cc_din_vld_w),
    .dout(cc_dout_mux), .dout_vld(cc_dout_vld_mux)
  );

  // Fan out configuration beats to all instances.
  for (genvar gi = 0; gi < N_LVDS_INST; gi++) begin : g_ccfan
    assign lvcfg_din[gi]     = cc_din_w;
    assign lvcfg_din_vld[gi] = cc_din_vld_w;
  end

  // Unused UART transmitter idles high.
  assign uart_tx    = 1'b1;

endmodule
