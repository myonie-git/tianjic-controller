// File        : tb_tj_ctrl_chip.sv
// Module      : tb_tj_ctrl_chip
// Description : Controller integration testbench for the native chip simulation.
//               Loads core templates through native memory hooks or BOOT SPI.
//               TJ_MULTI_DIE selects 2x2 dies; TJ_MULTI_DIE_4X1 selects 4x1 dies.
//               Enable with +use_tj_ctrl and select the image tool with +TJ_PY.
`include "tb.define.v"

module tb_tj_ctrl_chip;

  // Die hierarchy in the native single- and multi-die environments.
`ifdef TJ_MULTI_DIE
  `define TJD(R,C) top.packed_chip_top.gen_die_rows[R].gen_die_columns[C].u_chip_top
  `define TJD0 `TJD(0,0)
`else
  `define TJD0 top.full_chip
`endif

  logic pclk = 0, presetn = 0, maxi_clk = 0, maxi_rstn = 0, bclk_fpga = 0;
  always #5ns    pclk = ~pclk;
  always #1.2ns  maxi_clk = ~maxi_clk;    // 416.7 MHz.
  always #0.5ns  bclk_fpga = ~bclk_fpga;  // 1 GHz TX bit clock.

  int unsigned errs = 0, checks = 0;
  task automatic chk(input bit c, input string m);
    checks++;
    if (!c) begin
      errs++;
      $display("CTRL CHIP TB FAIL: %s @%0t", m, $time);
    end
  endtask

  // Controller top-level ports.
  logic psel, penable, pwrite;
  logic [15:0] paddr;
  logic [31:0] pwdata, prdata;
  logic pready, pslverr;
  logic [7:0] sclk_w, mosi_w;
  logic [31:0] cs_w, miso_w;
  // AXI reads for SEND and BOOT, and writes for RECV.
  logic        arvalid_w, arready_w, rvalid_w, rready_w, rlast_w;
  logic [3:0]  arid_w, rid_w;
  logic [47:0] araddr_w;
  logic [7:0]  arlen_w;
  logic [2:0]  arsize_w;
  logic [1:0]  arburst_w, rresp_w;
  logic [127:0] rdata_w;
  logic        awvalid_w, awready_w, wvalid_w, wready_w, wlast_w, bvalid_w, bready_w;
  logic [3:0]  awid_w, bid_w;
  logic [47:0] awaddr_w;
  logic [7:0]  awlen_w;
  logic [2:0]  awsize_w;
  logic [1:0]  awburst_w, bresp_w;
  logic [127:0] wdata_w;
  logic [15:0]  wstrb_w;
  // Four packet ports on one LVDS instance.
  logic [3:0]        lv_txv_w, lv_txr_w, lv_rxv_w, lv_rxr_w;
  logic [3:0][95:0]  lv_txd_w, lv_rxd_w;
  logic [32:0] lvcfg_din_w;
  logic        lvcfg_dvld_w;
  logic [31:0] lvcfg_dout_w;
  logic        lvcfg_dovld_w;

  tj_ctrl_top u_tjc (
    .pclk, .presetn, .maxi_clk, .maxi_rstn,
    .psel, .penable, .pwrite, .paddr, .pwdata, .pready, .pslverr, .prdata,
    .awvalid(awvalid_w), .awready(awready_w), .awid(awid_w), .awaddr(awaddr_w),
    .awuser(), .awlen(awlen_w), .awsize(awsize_w), .awburst(awburst_w),
    .wvalid(wvalid_w), .wready(wready_w), .wdata(wdata_w), .wstrb(wstrb_w), .wlast(wlast_w),
    .bvalid(bvalid_w), .bready(bready_w), .bresp(bresp_w), .bid(bid_w),
    .arvalid(arvalid_w), .arready(arready_w), .arid(arid_w), .araddr(araddr_w),
    .aruser(), .arlen(arlen_w), .arsize(arsize_w), .arburst(arburst_w),
    .rvalid(rvalid_w), .rready(rready_w), .rdata(rdata_w), .rresp(rresp_w),
    .rlast(rlast_w), .rid(rid_w),
    .s_axis_pk_tvalid(1'b0), .s_axis_pk_tready(), .s_axis_pk_tdata('0), .s_axis_pk_tlast(1'b0),
    .m_axis_pk_tvalid(), .m_axis_pk_tready(1'b0), .m_axis_pk_tdata(), .m_axis_pk_tlast(),
    .irq(),
    .lv_tx_tvalid(lv_txv_w), .lv_tx_tready(lv_txr_w), .lv_tx_tdata(lv_txd_w),
    .lv_rx_tvalid(lv_rxv_w), .lv_rx_tready(lv_rxr_w), .lv_rx_tdata(lv_rxd_w),
    .lvcfg_din(lvcfg_din_w), .lvcfg_din_vld(lvcfg_dvld_w),
    .lvcfg_dout(lvcfg_dout_w), .lvcfg_dout_vld(lvcfg_dovld_w),
    .spi_sclk(sclk_w), .spi_mosi(mosi_w), .spi_cs_n(cs_w), .spi_miso(miso_w),
    .chip_rst_n(), .clkctl(),
    .uart_rx(1'b1), .uart_tx()
  );

`ifdef TJ_MULTI_DIE_4X1
  // 4x1 die IDs are 0, 4, 8 and 12.
  assign miso_w = {19'b0, top.w_spis0_miso[3][0], 3'b000, top.w_spis0_miso[2][0],
                   3'b000, top.w_spis0_miso[1][0], 3'b000, top.w_spis0_miso[0][0]};
`elsif TJ_MULTI_DIE
  // 2x2 die IDs are 0, 1, 4 and 5.
  assign miso_w = {26'b0, top.w_spis0_miso[1][1], top.w_spis0_miso[1][0], 2'b00,
                   top.w_spis0_miso[0][1], top.w_spis0_miso[0][0]};
`else
  assign miso_w = {31'b0, top.w_spis0_miso};
`endif

  // FPGA-side link model using the chip LVDS wrapper.
  logic [1:0] fpga_idn;
  wire [2:0]      f_txc_p, f_txc_n, f_rxc_p, f_rxc_n;
  wire [2:0][4:0] f_txd_p, f_txd_n, f_rxd_p, f_rxd_n;

  tj_lnk_plug_chip u_fpga_lnk (
    .core_id(2'd0), .core_id_next(fpga_idn),
    .apb_pclk(pclk), .axis_brg_clk(maxi_clk), .lvds_tx_bclk(bclk_fpga),
    .rstn_raw(presetn),
    .s_tvalid(lv_txv_w), .s_tready(lv_txr_w), .s_tdata(lv_txd_w),
    .m_tvalid(lv_rxv_w), .m_tready(lv_rxr_w), .m_tdata(lv_rxd_w),
    .cfg_din(lvcfg_din_w), .cfg_din_vld(lvcfg_dvld_w),
    .cfg_dout(lvcfg_dout_w), .cfg_dout_vld(lvcfg_dovld_w),
    .cfg_din_next(), .cfg_din_next_vld(),
    .cfg_dout_next(32'h0), .cfg_dout_next_vld(1'b0),
    .err_intr(), .send_mode(),
    .txc_p(f_txc_p), .txc_n(f_txc_n), .txd_p(f_txd_p), .txd_n(f_txd_n),
    .rxc_p(f_rxc_p), .rxc_n(f_rxc_n), .rxd_p(f_rxd_p), .rxd_n(f_rxd_n)
  );

  // Connect chip west-side TX pads to the link model RX.
  assign f_rxc_p[0] = `TJD0.W__TX0_LVDS_CLK_P;  assign f_rxc_n[0] = `TJD0.W__TX0_LVDS_CLK_N;
  assign f_rxd_p[0][0] = `TJD0.W__TX0_LVDS_DAT0_P; assign f_rxd_n[0][0] = `TJD0.W__TX0_LVDS_DAT0_N;
  assign f_rxd_p[0][1] = `TJD0.W__TX0_LVDS_DAT1_P; assign f_rxd_n[0][1] = `TJD0.W__TX0_LVDS_DAT1_N;
  assign f_rxd_p[0][2] = `TJD0.W__TX0_LVDS_DAT2_P; assign f_rxd_n[0][2] = `TJD0.W__TX0_LVDS_DAT2_N;
  assign f_rxd_p[0][3] = `TJD0.W__TX0_LVDS_DAT3_P; assign f_rxd_n[0][3] = `TJD0.W__TX0_LVDS_DAT3_N;
  assign f_rxd_p[0][4] = `TJD0.W__TX0_LVDS_DAT4_P; assign f_rxd_n[0][4] = `TJD0.W__TX0_LVDS_DAT4_N;
  assign f_rxc_p[1] = `TJD0.W__TX1_LVDS_CLK_P;  assign f_rxc_n[1] = `TJD0.W__TX1_LVDS_CLK_N;
  assign f_rxd_p[1][0] = `TJD0.W__TX1_LVDS_DAT0_P; assign f_rxd_n[1][0] = `TJD0.W__TX1_LVDS_DAT0_N;
  assign f_rxd_p[1][1] = `TJD0.W__TX1_LVDS_DAT1_P; assign f_rxd_n[1][1] = `TJD0.W__TX1_LVDS_DAT1_N;
  assign f_rxd_p[1][2] = `TJD0.W__TX1_LVDS_DAT2_P; assign f_rxd_n[1][2] = `TJD0.W__TX1_LVDS_DAT2_N;
  assign f_rxd_p[1][3] = `TJD0.W__TX1_LVDS_DAT3_P; assign f_rxd_n[1][3] = `TJD0.W__TX1_LVDS_DAT3_N;
  assign f_rxd_p[1][4] = `TJD0.W__TX1_LVDS_DAT4_P; assign f_rxd_n[1][4] = `TJD0.W__TX1_LVDS_DAT4_N;
  assign f_rxc_p[2] = `TJD0.W__TX2_LVDS_CLK_P;  assign f_rxc_n[2] = `TJD0.W__TX2_LVDS_CLK_N;
  assign f_rxd_p[2][0] = `TJD0.W__TX2_LVDS_DAT0_P; assign f_rxd_n[2][0] = `TJD0.W__TX2_LVDS_DAT0_N;
  assign f_rxd_p[2][1] = `TJD0.W__TX2_LVDS_DAT1_P; assign f_rxd_n[2][1] = `TJD0.W__TX2_LVDS_DAT1_N;
  assign f_rxd_p[2][2] = `TJD0.W__TX2_LVDS_DAT2_P; assign f_rxd_n[2][2] = `TJD0.W__TX2_LVDS_DAT2_N;
  assign f_rxd_p[2][3] = `TJD0.W__TX2_LVDS_DAT3_P; assign f_rxd_n[2][3] = `TJD0.W__TX2_LVDS_DAT3_N;
  assign f_rxd_p[2][4] = `TJD0.W__TX2_LVDS_DAT4_P; assign f_rxd_n[2][4] = `TJD0.W__TX2_LVDS_DAT4_N;

  // Override native testbench drivers on the chip west-side RX pads.
  task automatic take_west_pads();
    force `TJD0.W__RX0_LVDS_CLK_P  = f_txc_p[0];  force `TJD0.W__RX0_LVDS_CLK_N  = f_txc_n[0];
    force `TJD0.W__RX0_LVDS_DAT0_P = f_txd_p[0][0]; force `TJD0.W__RX0_LVDS_DAT0_N = f_txd_n[0][0];
    force `TJD0.W__RX0_LVDS_DAT1_P = f_txd_p[0][1]; force `TJD0.W__RX0_LVDS_DAT1_N = f_txd_n[0][1];
    force `TJD0.W__RX0_LVDS_DAT2_P = f_txd_p[0][2]; force `TJD0.W__RX0_LVDS_DAT2_N = f_txd_n[0][2];
    force `TJD0.W__RX0_LVDS_DAT3_P = f_txd_p[0][3]; force `TJD0.W__RX0_LVDS_DAT3_N = f_txd_n[0][3];
    force `TJD0.W__RX0_LVDS_DAT4_P = f_txd_p[0][4]; force `TJD0.W__RX0_LVDS_DAT4_N = f_txd_n[0][4];
    force `TJD0.W__RX1_LVDS_CLK_P  = f_txc_p[1];  force `TJD0.W__RX1_LVDS_CLK_N  = f_txc_n[1];
    force `TJD0.W__RX1_LVDS_DAT0_P = f_txd_p[1][0]; force `TJD0.W__RX1_LVDS_DAT0_N = f_txd_n[1][0];
    force `TJD0.W__RX1_LVDS_DAT1_P = f_txd_p[1][1]; force `TJD0.W__RX1_LVDS_DAT1_N = f_txd_n[1][1];
    force `TJD0.W__RX1_LVDS_DAT2_P = f_txd_p[1][2]; force `TJD0.W__RX1_LVDS_DAT2_N = f_txd_n[1][2];
    force `TJD0.W__RX1_LVDS_DAT3_P = f_txd_p[1][3]; force `TJD0.W__RX1_LVDS_DAT3_N = f_txd_n[1][3];
    force `TJD0.W__RX1_LVDS_DAT4_P = f_txd_p[1][4]; force `TJD0.W__RX1_LVDS_DAT4_N = f_txd_n[1][4];
    force `TJD0.W__RX2_LVDS_CLK_P  = f_txc_p[2];  force `TJD0.W__RX2_LVDS_CLK_N  = f_txc_n[2];
    force `TJD0.W__RX2_LVDS_DAT0_P = f_txd_p[2][0]; force `TJD0.W__RX2_LVDS_DAT0_N = f_txd_n[2][0];
    force `TJD0.W__RX2_LVDS_DAT1_P = f_txd_p[2][1]; force `TJD0.W__RX2_LVDS_DAT1_N = f_txd_n[2][1];
    force `TJD0.W__RX2_LVDS_DAT2_P = f_txd_p[2][2]; force `TJD0.W__RX2_LVDS_DAT2_N = f_txd_n[2][2];
    force `TJD0.W__RX2_LVDS_DAT3_P = f_txd_p[2][3]; force `TJD0.W__RX2_LVDS_DAT3_N = f_txd_n[2][3];
    force `TJD0.W__RX2_LVDS_DAT4_P = f_txd_p[2][4]; force `TJD0.W__RX2_LVDS_DAT4_N = f_txd_n[2][4];
  endtask

  // AXI memory model: SEND image and three RECV rings, spaced 1 MiB apart.
  localparam longint unsigned IMG_BASE  = 64'h0000_1000_0000;
  localparam longint unsigned RING_BASE = 64'h0000_2000_0000;
  localparam int unsigned RING_RECS = 1024;
  logic [127:0] ddr [longint unsigned];
  logic [7:0] img_b [0:(1<<22)-1];
  typedef struct { logic [47:0] addr; logic [7:0] len; logic [3:0] id; } ar_t;
  typedef struct { logic [47:0] addr; logic [3:0] id; } aw_t;
  ar_t arq[$];
  aw_t awq[$];
  logic [127:0] wq[$];
  int ar_stall;

  always @(posedge maxi_clk) ar_stall <= $urandom_range(0, 9);
  assign arready_w = maxi_rstn && (ar_stall != 0);
  always @(posedge maxi_clk) if (arvalid_w && arready_w) begin
    ar_t a;
    chk(arsize_w === 3'd4 && arburst_w === 2'b01, "AXI read uses 16-byte INCR beats");
    chk(araddr_w[3:0] === 4'h0, "AXI read address is 16-byte aligned");
    a.addr = araddr_w;
    a.len = arlen_w;
    a.id = arid_w;
    arq.push_back(a);
  end
  initial begin
    rvalid_w = 0; rdata_w = '0; rresp_w = 2'b00; rlast_w = 0; rid_w = '0;
    wait (maxi_rstn);
    forever begin
      @(posedge maxi_clk);
      if (arq.size() > 0) begin
        automatic ar_t a = arq.pop_front();
        for (int b = 0; b <= a.len; b++) begin
          while ($urandom_range(0, 3) == 0) @(posedge maxi_clk);
          rvalid_w <= 1;
          rdata_w <= ddr.exists((a.addr >> 4) + b) ? ddr[(a.addr >> 4) + b] : '0;
          rresp_w <= 2'b00;
          rid_w <= a.id;
          rlast_w <= (b == a.len);
          @(posedge maxi_clk);
          while (rready_w !== 1'b1) @(posedge maxi_clk);
          rvalid_w <= 0;
          rlast_w <= 0;
        end
      end
    end
  end

  // RECV writes one complete 16-byte record per AXI transaction.
  assign awready_w = maxi_rstn;
  assign wready_w = maxi_rstn;
  always @(posedge maxi_clk) begin
    if (awvalid_w && awready_w) begin
      aw_t a;
      chk(awlen_w === 8'h0 && awsize_w === 3'd4 && awburst_w === 2'b01,
          "AXI write uses one 16-byte INCR beat");
      chk(awaddr_w[3:0] === 4'h0, "AXI write address is 16-byte aligned");
      a.addr = awaddr_w;
      a.id = awid_w;
      awq.push_back(a);
    end
    if (wvalid_w && wready_w) begin
      chk(wstrb_w === 16'hFFFF && wlast_w === 1'b1, "AXI writes every record byte");
      wq.push_back(wdata_w);
    end
  end
  initial begin
    bvalid_w = 0; bresp_w = 2'b00; bid_w = '0;
    wait (maxi_rstn);
    forever begin
      @(posedge maxi_clk);
      if (awq.size() > 0 && wq.size() > 0) begin
        automatic aw_t a = awq.pop_front();
        automatic logic [127:0] d = wq.pop_front();
        ddr[a.addr >> 4] = d;
        bvalid_w <= 1;
        bresp_w <= 2'b00;
        bid_w <= a.id;
        @(posedge maxi_clk);
        while (bready_w !== 1'b1) @(posedge maxi_clk);
        bvalid_w <= 0;
      end
    end
  end

  // Host APB accesses.
  task automatic apb_wr(input [15:0] a, input [31:0] d);
    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 1; paddr <= a; pwdata <= d;
    @(posedge pclk); penable <= 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    chk(pready === 1'b1, $sformatf("APB write PREADY at %04h", a));
    chk(pslverr === 1'b0, $sformatf("APB write PSLVERR at %04h", a));
    psel <= 0; penable <= 0; @(posedge pclk);
  endtask
  task automatic apb_rd(input [15:0] a, output [31:0] d);
    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 0; paddr <= a;
    @(posedge pclk); penable <= 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    d = prdata;
    chk(pready === 1'b1, $sformatf("APB read PREADY at %04h", a));
    chk(pslverr === 1'b0, $sformatf("APB read PSLVERR at %04h", a));
    psel <= 0; penable <= 0; @(posedge pclk);
  endtask

  logic [19:0] cur_offs = 20'hFFFFF;
  task automatic win_access(input bit wr, input [31:0] a, inout [31:0] d);
    if (a[31:12] != cur_offs) begin
      apb_wr(16'h3C08, {12'h0, a[31:12]});
      cur_offs = a[31:12];
    end
    if (wr) apb_wr({4'h4, a[11:0]}, d);
    else    apb_rd({4'h4, a[11:0]}, d);
  endtask

  task automatic core_read(input [31:0] a, output [31:0] d);
    logic [31:0] t;
    win_access(1'b0, a, t);
    for (int i = 0; i < 50; i++) begin
      win_access(1'b0, 32'h02FFF008, t);
      if (t[1]) break;
    end
    chk(t[1], $sformatf("Core configuration read %08x did not complete", a));
    t = 32'h2; win_access(1'b1, 32'h02FFF008, t);
    win_access(1'b0, 32'h02FFF010, d);
  endtask

  // FPGA-side LVDS configuration through the Controller CC registers.
  task automatic cc_beat(input [1:0] kind, input [31:0] wd);
    logic [31:0] s;
    apb_wr(16'h3800, {26'h0, 2'b00, 2'h0, kind});   // Instance 0.
    apb_wr(16'h3804, wd);
    apb_wr(16'h380C, 32'h1);                        // Start the command.
    for (int i = 0; i < 200; i++) begin
      apb_rd(16'h3810, s);
      if (!s[0]) break;
    end
    chk(!s[0], "Configuration-chain BUSY did not clear");
  endtask
  task automatic cc_write(input [24:0] a, input [31:0] d);
    cc_beat(2'd0, {7'h0, a});
    cc_beat(2'd1, d);
  endtask
  task automatic cc_read(input [24:0] a, output [31:0] d);
    logic [31:0] s;
    apb_wr(16'h3810, 32'h100);                      // Clear the previous read-valid flag.
    cc_beat(2'd2, {7'h0, a});
    apb_rd(16'h3810, s);
    chk(s[8], $sformatf("Configuration-chain read %h has no result", a));
    apb_rd(16'h3808, d);
    apb_wr(16'h3810, 32'h100);
  endtask

  // Native core memory hooks for the 4-by-4 core array.
  `define CM(AY,AX,CY,CX) `TJD0.u_cores_wrapper_top.gen_array_row[AY].gen_array_column[AX].u_array.gen_core_rows[CY].gen_core_columns[CX].u_core.core_memory
  task automatic core_mem_init(input int y, input int x, input string p);
    case ({y[1:0], x[1:0]})
      4'b0000: `CM(0,0,0,0).init_memory_from_file(p);
      4'b0001: `CM(0,0,0,1).init_memory_from_file(p);
      4'b0010: `CM(0,1,0,0).init_memory_from_file(p);
      4'b0011: `CM(0,1,0,1).init_memory_from_file(p);
      4'b0100: `CM(0,0,1,0).init_memory_from_file(p);
      4'b0101: `CM(0,0,1,1).init_memory_from_file(p);
      4'b0110: `CM(0,1,1,0).init_memory_from_file(p);
      4'b0111: `CM(0,1,1,1).init_memory_from_file(p);
      4'b1000: `CM(1,0,0,0).init_memory_from_file(p);
      4'b1001: `CM(1,0,0,1).init_memory_from_file(p);
      4'b1010: `CM(1,1,0,0).init_memory_from_file(p);
      4'b1011: `CM(1,1,0,1).init_memory_from_file(p);
      4'b1100: `CM(1,0,1,0).init_memory_from_file(p);
      4'b1101: `CM(1,0,1,1).init_memory_from_file(p);
      4'b1110: `CM(1,1,1,0).init_memory_from_file(p);
      4'b1111: `CM(1,1,1,1).init_memory_from_file(p);
    endcase
  endtask
  task automatic core_mem_dump(input int y, input int x, input string gold, input string outp);
    case ({y[1:0], x[1:0]})
      4'b0000: `CM(0,0,0,0).store_memory_from_addr_file(gold, outp);
      4'b0001: `CM(0,0,0,1).store_memory_from_addr_file(gold, outp);
      4'b0010: `CM(0,1,0,0).store_memory_from_addr_file(gold, outp);
      4'b0011: `CM(0,1,0,1).store_memory_from_addr_file(gold, outp);
      4'b0100: `CM(0,0,1,0).store_memory_from_addr_file(gold, outp);
      4'b0101: `CM(0,0,1,1).store_memory_from_addr_file(gold, outp);
      4'b0110: `CM(0,1,1,0).store_memory_from_addr_file(gold, outp);
      4'b0111: `CM(0,1,1,1).store_memory_from_addr_file(gold, outp);
      4'b1000: `CM(1,0,0,0).store_memory_from_addr_file(gold, outp);
      4'b1001: `CM(1,0,0,1).store_memory_from_addr_file(gold, outp);
      4'b1010: `CM(1,1,0,0).store_memory_from_addr_file(gold, outp);
      4'b1011: `CM(1,1,0,1).store_memory_from_addr_file(gold, outp);
      4'b1100: `CM(1,0,1,0).store_memory_from_addr_file(gold, outp);
      4'b1101: `CM(1,0,1,1).store_memory_from_addr_file(gold, outp);
      4'b1110: `CM(1,1,1,0).store_memory_from_addr_file(gold, outp);
      4'b1111: `CM(1,1,1,1).store_memory_from_addr_file(gold, outp);
    endcase
  endtask

`ifdef TJ_MULTI_DIE
  // Select a die and local core using constant hierarchical paths.
  `define CMD(DR,DC,AY,AX,CY,CX) `TJD(DR,DC).u_cores_wrapper_top.gen_array_row[AY].gen_array_column[AX].u_array.gen_core_rows[CY].gen_core_columns[CX].u_core.core_memory
  `define CM16MD(DR,DC) \
    case ({y[1:0], x[1:0]}) \
      4'b0000: `CMD(DR,DC,0,0,0,0).init_memory_from_file(p); \
      4'b0001: `CMD(DR,DC,0,0,0,1).init_memory_from_file(p); \
      4'b0010: `CMD(DR,DC,0,1,0,0).init_memory_from_file(p); \
      4'b0011: `CMD(DR,DC,0,1,0,1).init_memory_from_file(p); \
      4'b0100: `CMD(DR,DC,0,0,1,0).init_memory_from_file(p); \
      4'b0101: `CMD(DR,DC,0,0,1,1).init_memory_from_file(p); \
      4'b0110: `CMD(DR,DC,0,1,1,0).init_memory_from_file(p); \
      4'b0111: `CMD(DR,DC,0,1,1,1).init_memory_from_file(p); \
      4'b1000: `CMD(DR,DC,1,0,0,0).init_memory_from_file(p); \
      4'b1001: `CMD(DR,DC,1,0,0,1).init_memory_from_file(p); \
      4'b1010: `CMD(DR,DC,1,1,0,0).init_memory_from_file(p); \
      4'b1011: `CMD(DR,DC,1,1,0,1).init_memory_from_file(p); \
      4'b1100: `CMD(DR,DC,1,0,1,0).init_memory_from_file(p); \
      4'b1101: `CMD(DR,DC,1,0,1,1).init_memory_from_file(p); \
      4'b1110: `CMD(DR,DC,1,1,1,0).init_memory_from_file(p); \
      4'b1111: `CMD(DR,DC,1,1,1,1).init_memory_from_file(p); \
    endcase
  task automatic core_mem_init_md(input int dr, input int dc,
                                  input int y, input int x, input string p);
`ifdef TJ_MULTI_DIE_4X1
    case (dr[1:0])
      2'd0: `CM16MD(0,0)
      2'd1: `CM16MD(1,0)
      2'd2: `CM16MD(2,0)
      2'd3: `CM16MD(3,0)
    endcase
`else
    case ({dr[0], dc[0]})
      2'b00: `CM16MD(0,0)
      2'b01: `CM16MD(0,1)
      2'b10: `CM16MD(1,0)
      2'b11: `CM16MD(1,1)
    endcase
`endif
  endtask
  `define CD16MD(DR,DC) \
    case ({y[1:0], x[1:0]}) \
      4'b0000: `CMD(DR,DC,0,0,0,0).store_memory_from_addr_file(gold, outp); \
      4'b0001: `CMD(DR,DC,0,0,0,1).store_memory_from_addr_file(gold, outp); \
      4'b0010: `CMD(DR,DC,0,1,0,0).store_memory_from_addr_file(gold, outp); \
      4'b0011: `CMD(DR,DC,0,1,0,1).store_memory_from_addr_file(gold, outp); \
      4'b0100: `CMD(DR,DC,0,0,1,0).store_memory_from_addr_file(gold, outp); \
      4'b0101: `CMD(DR,DC,0,0,1,1).store_memory_from_addr_file(gold, outp); \
      4'b0110: `CMD(DR,DC,0,1,1,0).store_memory_from_addr_file(gold, outp); \
      4'b0111: `CMD(DR,DC,0,1,1,1).store_memory_from_addr_file(gold, outp); \
      4'b1000: `CMD(DR,DC,1,0,0,0).store_memory_from_addr_file(gold, outp); \
      4'b1001: `CMD(DR,DC,1,0,0,1).store_memory_from_addr_file(gold, outp); \
      4'b1010: `CMD(DR,DC,1,1,0,0).store_memory_from_addr_file(gold, outp); \
      4'b1011: `CMD(DR,DC,1,1,0,1).store_memory_from_addr_file(gold, outp); \
      4'b1100: `CMD(DR,DC,1,0,1,0).store_memory_from_addr_file(gold, outp); \
      4'b1101: `CMD(DR,DC,1,0,1,1).store_memory_from_addr_file(gold, outp); \
      4'b1110: `CMD(DR,DC,1,1,1,0).store_memory_from_addr_file(gold, outp); \
      4'b1111: `CMD(DR,DC,1,1,1,1).store_memory_from_addr_file(gold, outp); \
    endcase
  task automatic core_mem_dump_md(input int dr, input int dc, input int y, input int x,
                                  input string gold, input string outp);
`ifdef TJ_MULTI_DIE_4X1
    case (dr[1:0])
      2'd0: `CD16MD(0,0)
      2'd1: `CD16MD(1,0)
      2'd2: `CD16MD(2,0)
      2'd3: `CD16MD(3,0)
    endcase
`else
    case ({dr[0], dc[0]})
      2'b00: `CD16MD(0,0)
      2'b01: `CD16MD(0,1)
      2'b10: `CD16MD(1,0)
      2'b11: `CD16MD(1,1)
    endcase
`endif
  endtask
`endif

  // Send a table and check its completed count after snapshot propagation.
  task automatic send_table(input logic [47:0] src, input int unsigned count,
                            input int unsigned poll_limit);
    logic [31:0] status, sent_value;
    apb_wr(16'h0C10, 32'h300);
    apb_wr(16'h0C00, src[31:0]);
    apb_wr(16'h0C04, {16'h0, src[47:32]});
    apb_wr(16'h0C08, count);
    apb_wr(16'h0C0C, 32'h1);
    for (int i = 0; i < poll_limit; i++) begin
      apb_rd(16'h0C10, status);
      if (status[9] === 1'b1 || (status[8] === 1'b1 && status[0] === 1'b0)) break;
    end
    chk(status[8] === 1'b1 && status[0] === 1'b0, "SEND completes and becomes idle");
    chk(status[9] === 1'b0, "SEND has no error");
    // Allow an in-flight snapshot to finish before checking this task's SENT value.
    repeat (12) begin
      @(negedge maxi_clk);
      @(negedge pclk);
    end
    for (int i = 0; i < 2000; i++) begin
      apb_rd(16'h0C14, sent_value);
      if (sent_value === count) break;
    end
    chk(sent_value === count, $sformatf("SENT=%0d, expected %0d", sent_value, count));
    apb_wr(16'h0C10, 32'h300);
  endtask

  // Match the injected data packet by content, even when other packets arrive first.
  logic [127:0] last_bounce_rec;
  task automatic bounce_pkt(input logic [63:0] body, output int hit);
    logic [31:0] first_rec[3], next_rec[3], wp_now;
    logic [127:0] r;
    for (int c = 0; c < 3; c++) begin
      apb_rd(16'h1000 + 16'(c)*16'h40 + 16'h18, next_rec[c]);
      first_rec[c] = next_rec[c];
    end
    ddr[(64'h0000_1800_0000 >> 4)] =
      {16'hD0D0, 8'h01, 8'h00, body, 14'h0, 6'b100000, 6'h0, 2'b00, 4'b0010};
    send_table(48'h0000_1800_0000, 1, 2000);
    hit = -1;
    last_bounce_rec = '0;
    for (int t = 0; t < 3000 && hit < 0; t++) begin
      for (int c = 0; c < 3; c++) begin
        apb_rd(16'h1000 + 16'(c)*16'h40 + 16'h18, wp_now);
        while (next_rec[c] < wp_now) begin
          r = ddr[((RING_BASE + longint'(c)*64'h10_0000) >> 4)
                  + longint'(next_rec[c] % RING_RECS)];
          next_rec[c]++;
          if (r[2:0] === 3'b010 && r[95:32] === body) begin
            hit = c;
            last_bounce_rec = r;
            break;
          end
        end
        if (hit >= 0) break;
      end
    end
    if (hit < 0) begin
      for (int c = 0; c < 3; c++)
        $display("CTRL CHIP TB: body=%016h not found in ring %0d, scanned [%0d,%0d)",
                 body, c, first_rec[c], next_rec[c]);
    end
  endtask

  localparam longint unsigned BOOT_STAGE = 64'h0000_5000_0000;
  localparam logic [31:0] CORE_LS_ADDR =
      tj_ctrl_pkg::CHIP_CORE_REG_BASE + 32'(tj_ctrl_pkg::CORE_REG_LS);
  typedef struct { int y, x, boot_bytes; } core_t;
  core_t cores[$];
  int unsigned boot_verified_cores = 0;
  string case_p, tj_py;

  // Stage 1 to 4 consecutive 32-byte rows starting at row 0.
  task automatic boot_stage_core(input int idx, input string path, output int bytes);
    int fd, rows, fields;
    string line, tag, expected_tag, extra;
    logic [255:0] row_data;
    longint unsigned beat_addr;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    rows = 0;
    beat_addr = (BOOT_STAGE >> 4) + longint'(idx) * 16;
    while ($fgets(line, fd)) begin
      fields = $sscanf(line, "%s %h %s", tag, row_data, extra);
      if (fields <= 0) continue;
      if (fields != 2 || $isunknown(row_data))
        $fatal(1, "%s: expected @row and hexadecimal BOOT data", path);
      if (rows == 4) $fatal(1, "%s: BOOT templates support at most 4 rows", path);
      // Match the next row, allowing zero-padded tags such as @0001.
      expected_tag = "@";
      for (int i = 2; i < tag.len(); i++) expected_tag = {expected_tag, "0"};
      expected_tag = {expected_tag, $sformatf("%0d", rows)};
      if (tag != expected_tag)
        $fatal(1, "%s: expected BOOT row @%0h, got %s", path, rows, tag);
      ddr[beat_addr + 2 * rows]     = row_data[127:0];
      ddr[beat_addr + 2 * rows + 1] = row_data[255:128];
      rows++;
    end
    $fclose(fd);
    if (rows == 0) $fatal(1, "%s: empty BOOT template", path);
    bytes = rows * 32;
  endtask

  task automatic set_core_ls(input logic [31:0] value);
    logic [31:0] actual;
    win_access(1'b1, CORE_LS_ADDR, value);
    core_read(CORE_LS_ADDR, actual);
    chk(actual[1:0] === value[1:0],
        $sformatf("LS_CONTROL wrote %h, read %h", value, actual));
  endtask

  task automatic boot_deliver_cores();
    logic [31:0] status;
    foreach (cores[i]) begin
      logic [31:0] saved_ls;
      string golden, dump_path;
      int unsigned errs_before;

      errs_before = errs;
      status = 32'h1;
      win_access(1'b1, 32'h02FFF000, status);
      status = (cores[i].y << 2) | cores[i].x;
      win_access(1'b1, 32'h02FFF00C, status);
      core_read(CORE_LS_ADDR, saved_ls);
      if (errs != errs_before || $isunknown(saved_ls[1:0]))
        $fatal(1, "Cannot read LS_CONTROL for core (%0d,%0d)", cores[i].y, cores[i].x);

      set_core_ls(saved_ls & ~32'h3);
      if (errs != errs_before) begin
        set_core_ls(saved_ls);
        $fatal(1, "Cannot wake core (%0d,%0d)", cores[i].y, cores[i].x);
      end

      apb_wr(16'h0800, 32'h1);  // BOOT_PRIM, die 0.
      apb_wr(16'h0804, BOOT_STAGE[31:0] + i * 32'h100);
      apb_wr(16'h0808, {16'h0, BOOT_STAGE[47:32]});
      apb_wr(16'h080C, cores[i].boot_bytes);
      apb_wr(16'h0810, tj_ctrl_pkg::CHIP_CORE_MEM_BASE);
      apb_wr(16'h0814, 32'h1);
      status = 0;
      for (int t = 0; t < 20000 && !status[8]; t++) apb_rd(16'h0818, status);
      chk(status[8], $sformatf("BOOT did not finish for core (%0d,%0d)", cores[i].y, cores[i].x));
      chk(!status[9], $sformatf("BOOT error %0d for core (%0d,%0d)",
                                status[15:12], cores[i].y, cores[i].x));
      apb_wr(16'h0818, 32'h300);
      golden = $sformatf("%s/%0d_%0d_mem_config.txt", case_p, cores[i].y, cores[i].x);
      dump_path = $sformatf("bootchk_%0d_%0d.txt", cores[i].y, cores[i].x);
      core_mem_dump(cores[i].y, cores[i].x, golden, dump_path);
      chk($system($sformatf("env PYTHONIOENCODING=utf-8 python3 \"%s\" compare \"%s\" \"%s\" --mode memory",
                            tj_py, golden, dump_path)) == 0,
          $sformatf("BOOT memory readback for core (%0d,%0d)", cores[i].y, cores[i].x));

      set_core_ls(saved_ls);
      if (errs != errs_before)
        $fatal(1, "BOOT load failed for core (%0d,%0d)", cores[i].y, cores[i].x);
      boot_verified_cores++;
    end
    if ($test$plusargs("TJ_BOOTPROBE")) begin
      chk(boot_verified_cores == cores.size(),
          "All BOOT cores passed memory readback");
      if (errs == 0 && checks > 0) $display("CTRL CHIP TB PASS (%0d checks)", checks);
      else $fatal(1, "CTRL CHIP TB FAIL (%0d/%0d)", errs, checks);
      $finish;
    end
  endtask

  // Strip comments before parsing command operands.
  function automatic string command_text(input string line);
    for (int i = 0; i < line.len(); i++) begin
      if (line.getc(i) == 8'h23) begin
        if (i == 0) return "";
        return line.substr(0, i - 1);
      end
    end
    return line;
  endfunction

  int n_w, n_p, n_r, n_f, n_d;
  task automatic replay_regs(input string path, input bit lvds_mode, input int n_rec);
    int fd, code, line_no;
    string line, op, extra;
    logic [31:0] a_v, d_v, m_v, v_v, rdat;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    n_w = 0; n_p = 0; n_r = 0; n_f = 0; n_d = 0; line_no = 0;
    while ($fgets(line, fd)) begin
      line_no++;
      line = command_text(line);
      if ($sscanf(line, "%s", op) != 1) continue;
      case (op)
        "W": begin
          code = $sscanf(line, "%s %h %h %s", op, a_v, d_v, extra);
          if (code != 3) $fatal(1, "%s:%0d: expected W address data", path, line_no);
          win_access(1'b1, a_v, d_v);
          n_w++;
        end
        "D": begin
          code = $sscanf(line, "%s %d %s", op, d_v, extra);
          if (code != 2) $fatal(1, "%s:%0d: expected D die_id", path, line_no);
          apb_wr(16'h3C04, d_v);
          n_d++;
        end
        "R": begin
          code = $sscanf(line, "%s %h %h %h %s", op, a_v, m_v, v_v, extra);
          if (code != 4) $fatal(1, "%s:%0d: expected R address mask value", path, line_no);
          win_access(1'b0, a_v, rdat);
          chk((rdat & m_v) === v_v,
              $sformatf("Read %08h: %08h & %08h != %08h", a_v, rdat, m_v, v_v));
          n_r++;
        end
        "P": begin
          code = $sscanf(line, "%s %h %h %h %s", op, a_v, m_v, v_v, extra);
          if (code != 4) $fatal(1, "%s:%0d: expected P address mask value", path, line_no);
          for (int i = 0; i < 400; i++) begin
            core_read(a_v, rdat);
            if ((rdat & m_v) === v_v) break;
          end
          chk((rdat & m_v) === v_v,
              $sformatf("Poll %08h: %08h & %08h != %08h", a_v, rdat, m_v, v_v));
          n_p++;
        end
        "B": begin
          code = $sscanf(line, "%s %h %h %s", op, a_v, d_v, extra);
          if (code != 3) $fatal(1, "%s:%0d: expected B argument argument", path, line_no);
          if ($test$plusargs("TJ_BOOTSPI")) boot_deliver_cores();
        end
        "F": begin
          code = $sscanf(line, "%s %h %h %s", op, a_v, d_v, extra);
          if (code != 3) $fatal(1, "%s:%0d: expected F argument argument", path, line_no);
          if (!lvds_mode) $fatal(1, "F requires LVDS mode");
          send_table(IMG_BASE[47:0], n_rec, 20000);
          n_f++;
        end
        default: $fatal(1, "%s:%0d: unsupported command %s", path, line_no, op);
      endcase
    end
    $fclose(fd);
    if (lvds_mode && n_f == 0) $fatal(1, "LVDS command list contains no SEND marker");
  endtask

  // Save newly committed data packets; control packets do not count toward golden output.
  task automatic collect_output(input int ofd, ref logic [31:0] next_rec[3],
                                ref int n_data);
    logic [31:0] wp;
    logic [127:0] r;
    for (int c = 0; c < 3; c++) begin
      apb_rd(16'h1000 + 16'(c)*16'h40 + 16'h18, wp);
      if (next_rec[c] < wp) begin
        while (next_rec[c] < wp) begin
          r = ddr[((RING_BASE + longint'(c)*64'h10_0000) >> 4)
                  + longint'(next_rec[c] % RING_RECS)];
          chk(r[103:96] === 8'(c), $sformatf("RECV ring %0d channel tag", c));
          if (r[2:0] === 3'b010) begin
            $fwrite(ofd, "@%04h %016h\n", r[31:18], r[95:32]);
            n_data++;
          end
          next_rec[c]++;
        end
        apb_wr(16'h1000 + 16'(c)*16'h40 + 16'h1C, next_rec[c]);
      end
    end
  endtask

  // Main sequence.
  string regs_p, memcfg_p, golden_p, out_p, img_p, line;
  int comparisons = 0;
  int fd, code, gy, gx, n_rec;
  logic [31:0] rdat, d_v;
  bit lvds_mode;

  initial begin
    psel = 0; penable = 0; pwrite = 0; paddr = '0; pwdata = '0;
    if (!$test$plusargs("use_tj_ctrl")) begin
      $display("CTRL CHIP TB: Disabled: +use_tj_ctrl was not supplied");
      wait (0);
    end
    if (!$value$plusargs("TJ_PY=%s", tj_py))
      $fatal(1, "need +TJ_PY=<path to tj_image.py>");
    lvds_mode = $test$plusargs("TJ_LVDS");
    if (lvds_mode && !$value$plusargs("TJ_GOLDEN=%s", golden_p))
      $fatal(1, "LVDS mode requires +TJ_GOLDEN=");

`ifdef TJ_MULTI_DIE
    if ($test$plusargs("TJ_BOOTSPI"))
      $fatal(1, "BOOT-SPI loading is supported only by the single-die testbench");
`ifdef TJ_MULTI_DIE_4X1
    if (`DIE_ARRAY_H != 4 || `DIE_ARRAY_W != 1)
      $fatal(1, "TJ_MULTI_DIE_4X1 requires DIE_ARRAY_H=4 and DIE_ARRAY_W=1");
`else
    if (`DIE_ARRAY_H != 2 || `DIE_ARRAY_W != 2)
      $fatal(1, "TJ_MULTI_DIE requires DIE_ARRAY_H=2 and DIE_ARRAY_W=2");
`endif
`endif

    uvm_pkg::uvm_test_done.raise_objection(null, "Controller chip integration test");

`ifdef TJ_MULTI_DIE
    // Keep each die MCU in a spin loop.
`ifdef TJ_MULTI_DIE_4X1
    force `TJD(0,0).u_mcu_top.u_mcu_core.cpu_base_addr = 32'h01000000;
    force `TJD(1,0).u_mcu_top.u_mcu_core.cpu_base_addr = 32'h01000000;
    force `TJD(2,0).u_mcu_top.u_mcu_core.cpu_base_addr = 32'h01000000;
    force `TJD(3,0).u_mcu_top.u_mcu_core.cpu_base_addr = 32'h01000000;
    fork
      while (`TJD(0,0).u_mcu_top.u_mcu_core.u_riscv.cpu_hresetn !== 1'b1) begin
        for (int i = 0; i < 64; i++) begin
          `TJD(0,0).u_mcu_top.u_mcu_core.u_ahb_sramc.u_ram.u_ram.uut.write_mem_red(i, 32'h0000006F, 32'hFFFFFFFF);
          `TJD(1,0).u_mcu_top.u_mcu_core.u_ahb_sramc.u_ram.u_ram.uut.write_mem_red(i, 32'h0000006F, 32'hFFFFFFFF);
          `TJD(2,0).u_mcu_top.u_mcu_core.u_ahb_sramc.u_ram.u_ram.uut.write_mem_red(i, 32'h0000006F, 32'hFFFFFFFF);
          `TJD(3,0).u_mcu_top.u_mcu_core.u_ahb_sramc.u_ram.u_ram.uut.write_mem_red(i, 32'h0000006F, 32'hFFFFFFFF);
        end
        #100ns;
      end
    join_none

    // Share SCLK/MOSI per die row; use a separate CS per die.
    force top.w_spis0_clk  = {sclk_w[3], sclk_w[2], sclk_w[1], sclk_w[0]};
    force top.w_spis0_mosi = {mosi_w[3], mosi_w[2], mosi_w[1], mosi_w[0]};
    force top.w_spis0_csn  = {cs_w[12], cs_w[8], cs_w[4], cs_w[0]};
`else
    force `TJD(0,0).u_mcu_top.u_mcu_core.cpu_base_addr = 32'h01000000;
    force `TJD(0,1).u_mcu_top.u_mcu_core.cpu_base_addr = 32'h01000000;
    force `TJD(1,0).u_mcu_top.u_mcu_core.cpu_base_addr = 32'h01000000;
    force `TJD(1,1).u_mcu_top.u_mcu_core.cpu_base_addr = 32'h01000000;
    fork
      while (`TJD(0,0).u_mcu_top.u_mcu_core.u_riscv.cpu_hresetn !== 1'b1) begin
        for (int i = 0; i < 64; i++) begin
          `TJD(0,0).u_mcu_top.u_mcu_core.u_ahb_sramc.u_ram.u_ram.uut.write_mem_red(i, 32'h0000006F, 32'hFFFFFFFF);
          `TJD(0,1).u_mcu_top.u_mcu_core.u_ahb_sramc.u_ram.u_ram.uut.write_mem_red(i, 32'h0000006F, 32'hFFFFFFFF);
          `TJD(1,0).u_mcu_top.u_mcu_core.u_ahb_sramc.u_ram.u_ram.uut.write_mem_red(i, 32'h0000006F, 32'hFFFFFFFF);
          `TJD(1,1).u_mcu_top.u_mcu_core.u_ahb_sramc.u_ram.u_ram.uut.write_mem_red(i, 32'h0000006F, 32'hFFFFFFFF);
        end
        #100ns;
      end
    join_none

    // Share SCLK/MOSI per die row; use a separate CS per die.
    force top.w_spis0_clk  = {sclk_w[1], sclk_w[1], sclk_w[0], sclk_w[0]};
    force top.w_spis0_mosi = {mosi_w[1], mosi_w[1], mosi_w[0], mosi_w[0]};
    force top.w_spis0_csn  = {cs_w[5], cs_w[4], cs_w[1], cs_w[0]};
`endif
`else
    // Keep the MCU in a spin loop.
    force `MCU_SYS.cpu_base_addr = 32'h01000000;
    fork
      while (`CPU.cpu_hresetn !== 1'b1) begin
        for (int i = 0; i < 64; i++)
          `SYS_RAM0.uut.write_mem_red(i, 32'h0000006F, 32'hFFFFFFFF);
        #100ns;
      end
    join_none

    // Connect Controller SPI outputs to chip pads.
    force top.w_spis0_clk  = sclk_w[0];
    force top.w_spis0_csn  = cs_w[0];
    force top.w_spis0_mosi = mosi_w[0];
`endif
    if (lvds_mode) take_west_pads();
    $display("CTRL CHIP TB: Pad connections enabled (SPI%s) @%0t", lvds_mode ? "+west LVDS" : "", $time);

    repeat (20) @(posedge pclk);
    @(negedge pclk);
    presetn = 1; maxi_rstn = 1;

    wait (`TJD0.u_mcu_top.u_mcu_core.u_riscv.cpu_hresetn === 1'b1);
    $display("CTRL CHIP TB: Chip reset released @%0t", $time);
    repeat (200) @(posedge pclk);

    // Stage BOOT images in DDR or load core memory directly.
`ifdef TJ_MULTI_DIE
    if ($value$plusargs("TJ_CASE=%s", case_p)) begin
      int dfd, dr, dc;
      string dln;
      fd = $fopen({case_p, "/core_list.txt"}, "r");
      if (fd != 0) begin
        while ($fgets(line, fd)) begin
          int gy, gx;
          if ($sscanf(line, "%d %d", gy, gx) != 2) continue;
          core_mem_init_md(gy / 4, gx / 4, gy % 4, gx % 4,
            $sformatf("%s/%0d_%0d_mem_config.txt", case_p, gy, gx));
          $display("CTRL CHIP TB: Loaded die (%0d,%0d) core (%0d,%0d), global (%0d,%0d)",
                   gy / 4, gx / 4, gy % 4, gx % 4, gy, gx);
        end
        $fclose(fd);
      end else begin
        dfd = $fopen({case_p, "/die_list.txt"}, "r");
        if (dfd == 0) $fatal(1, "cannot open %s/{core_list,die_list}.txt", case_p);
        while ($fgets(dln, dfd)) begin
          if ($sscanf(dln, "%d %d", dr, dc) != 2) continue;
          fd = $fopen($sformatf("%s/die_%0d_%0d/core_list.txt", case_p, dr, dc), "r");
          if (fd == 0) $fatal(1, "cannot open die_%0d_%0d/core_list.txt", dr, dc);
          while ($fgets(line, fd)) begin
            int y, x;
            if ($sscanf(line, "%d %d", y, x) != 2) continue;
            core_mem_init_md(dr, dc, y, x,
              $sformatf("%s/die_%0d_%0d/%0d_%0d_mem_config.txt", case_p, dr, dc, y, x));
            $display("CTRL CHIP TB: Loaded die (%0d,%0d) core (%0d,%0d)", dr, dc, y, x);
          end
          $fclose(fd);
        end
        $fclose(dfd);
      end
    end
`else
    if ($value$plusargs("TJ_CASE=%s", case_p)) begin
      fd = $fopen({case_p, "/core_list.txt"}, "r");
      if (fd == 0) $fatal(1, "cannot open core_list");
      while ($fgets(line, fd)) begin
        core_t core;
        string token, extra;
        if ($sscanf(line, "%s", token) != 1) continue;
        code = $sscanf(line, "%d %d %s", core.y, core.x, extra);
        if (code != 2 || core.y < 0 || core.y > 3 || core.x < 0 || core.x > 3)
          $fatal(1, "Invalid core_list row: %s", line);
        if ($test$plusargs("TJ_BOOTSPI"))
          boot_stage_core(cores.size(), $sformatf("%s/%0d_%0d_mem_config.txt", case_p, core.y, core.x),
                          core.boot_bytes);
        else
          core_mem_init(core.y, core.x,
                        $sformatf("%s/%0d_%0d_mem_config.txt", case_p, core.y, core.x));
        cores.push_back(core);
      end
      $fclose(fd);
      if (cores.size() == 0) $fatal(1, "core_list contains no cores");
    end else if ($test$plusargs("TJ_BOOTSPI")) begin
      $fatal(1, "BOOT-SPI requires +TJ_CASE");
    end
`endif
    if (lvds_mode) begin
      if (case_p == "") $fatal(1, "need +TJ_CASE=");
      // Load SEND records into the DDR model.
      if (!$value$plusargs("TJ_IMG=%s", img_p)) $fatal(1, "need +TJ_IMG=");
      fd = $fopen(img_p, "rb");
      if (fd == 0) $fatal(1, "cannot open %s", img_p);
      begin
        int n;
        n = $fread(img_b, fd);
        if ($fgetc(fd) != -1) $fatal(1, "SEND image exceeds the 4 MiB input buffer");
        $fclose(fd);
        if (n == 0 || n % 16 != 0) $fatal(1, "SEND image must contain complete 16-byte records");
        n_rec = n / 16;
        for (int i = 0; i < n_rec; i++) begin
          logic [127:0] r;
          for (int b = 0; b < 16; b++) r[8*b +: 8] = img_b[i*16 + b];
          ddr[(IMG_BASE >> 4) + i] = r;
        end
        $display("CTRL CHIP TB: Loaded %0d SEND records into DDR", n_rec);
      end
    end
    if (case_p == "" && $value$plusargs("TJ_MEMCFG=%s", memcfg_p)) begin
      core_mem_init(0, 0, memcfg_p);
      $display("CTRL CHIP TB: Loaded core (0,0) memory from %s", memcfg_p);
    end

    // Configure SPI at 25 MHz and enable SPIWIN for die 0.
    apb_wr(16'h0410, 32'h1);
    apb_wr(16'h3C00, 32'h1);
    apb_wr(16'h3C04, 32'h0);

    // Configure the FPGA-side link model and SEND routing.
    if (lvds_mode) begin
      chk(fpga_idn === 2'd1, "FPGA link instance ID propagation");
      cc_write(25'h04, 32'h211F);                   // Link group parameters.
      cc_write(25'h24, 32'h211F);
      cc_write(25'h44, 32'h211F);
      cc_write(25'h00, 32'h4);                      // Enable parallel TX/RX and all-to-all mode.
      cc_write(25'h200, 32'h0);                     // Unmask link errors.
      #6us;                                         // Allow link startup to settle.
      cc_read(25'h204, rdat);
      $display("CTRL CHIP TB: Link startup ERR_ST=%08x", rdat);
      cc_write(25'h204, 32'hFFF);                   // Clear startup error flags.
      cc_read(25'h204, rdat);
      chk(rdat === 32'h0, $sformatf("Link ERR_ST after clearing=%08x", rdat));
      apb_wr(16'h2000, 32'h7);                      // Enable SEND channels 0 through 2.
      // Configure three bounded RECV rings with backpressure.
      for (int c = 0; c < 3; c++) begin
        logic [47:0] rb;
        rb = RING_BASE + longint'(c) * 64'h10_0000;
        apb_wr(16'h1000 + 16'(c) * 16'h40 + 16'h00, rb[31:0]);
        apb_wr(16'h1000 + 16'(c) * 16'h40 + 16'h04, {16'h0, rb[47:32]});
        apb_wr(16'h1000 + 16'(c) * 16'h40 + 16'h08, RING_RECS);
        apb_wr(16'h1000 + 16'(c) * 16'h40 + 16'h0C, 32'h100);
        apb_wr(16'h1000 + 16'(c) * 16'h40 + 16'h10, 32'h3);   // Receive enabled; backpressure when full.
      end
    end

    // Execute initialization commands, including SEND markers in LVDS mode.
    if (!$value$plusargs("TJ_REGS=%s", regs_p)) $fatal(1, "need +TJ_REGS=");
    replay_regs(regs_p, lvds_mode, n_rec);
    $display("CTRL CHIP TB: Commands executed: W=%0d P=%0d R=%0d F=%0d D=%0d @%0t",
             n_w, n_p, n_r, n_f, n_d, $time);

    // Check configuration readback and link error status.
    d_v = 32'hF; win_access(1'b1, 32'h02FFF00C, d_v);
    win_access(1'b0, 32'h02FFF00C, rdat);
    chk(rdat[3:0] === 4'hF, $sformatf("Core selection readback=%08x", rdat));
    d_v = 32'h0; win_access(1'b1, 32'h02FFF00C, d_v);
    if (lvds_mode) begin
      cc_read(25'h204, rdat);                       // Read the accumulated link errors.
      chk(rdat === 32'h0, $sformatf("Final link ERR_ST=%08x, expected zero", rdat));
    end

    // Compare actual outputs, using packet or final-memory semantics as appropriate.
    if (lvds_mode) begin
      int n_out, n_data, ofd;
      logic [31:0] next_rec[3];
      n_out = 4;
      void'($value$plusargs("TJ_NOUT=%d", n_out));
      if (n_out <= 0) $fatal(1, "TJ_NOUT must be positive");
      n_data = 0;
      foreach (next_rec[c]) next_rec[c] = 0;
      if (!$value$plusargs("TJ_OUT=%s", out_p)) out_p = "lvds_outputs.txt";
      ofd = $fopen(out_p, "w");
      if (ofd == 0) $fatal(1, "cannot open %s", out_p);
      for (int t = 0; t < 12000 && n_data < n_out; t++)
        collect_output(ofd, next_rec, n_data);
      repeat (400) @(posedge pclk);
      collect_output(ofd, next_rec, n_data);
      $fclose(ofd);
      chk(n_data == n_out, $sformatf("Received %0d data packets, expected %0d", n_data, n_out));
      comparisons++;
      if ($system($sformatf(
          "env PYTHONIOENCODING=utf-8 python3 \"%s\" compare \"%s\" \"%s\" --mode packets",
          tj_py, golden_p, out_p)) == 0)
        $display("CTRL CHIP TB: golden comparison PASS (%0d data packets)", n_data);
      else begin
        errs++;
        $display("CTRL CHIP TB FAIL: packet output differs from golden");
      end
    end else if (case_p != "") begin
`ifdef TJ_MULTI_DIE
      // Compare each core in flat or per-die case layouts.
      int dfd2, dr2, dc2;
      string dln2;
      fd = $fopen({case_p, "/core_list.txt"}, "r");
      if (fd != 0) begin
        while ($fgets(line, fd)) begin
          int gy, gx, gfd;
          string gp, op;
          if ($sscanf(line, "%d %d", gy, gx) != 2) continue;
          gp = $sformatf("%s/%0d_%0d_mem_output.txt", case_p, gy, gx);
          gfd = $fopen(gp, "r");
          if (gfd == 0) continue;
          $fclose(gfd);
          op = $sformatf("out_g%0d_%0d.txt", gy, gx);
          core_mem_dump_md(gy / 4, gx / 4, gy % 4, gx % 4, gp, op);
          comparisons++;
          if ($system($sformatf(
              "env PYTHONIOENCODING=utf-8 python3 \"%s\" compare \"%s\" \"%s\" --mode memory",
              tj_py, gp, op)) == 0)
            $display("CTRL CHIP TB: golden comparison PASS (die (%0d,%0d) core (%0d,%0d), global (%0d,%0d))",
                     gy / 4, gx / 4, gy % 4, gx % 4, gy, gx);
          else begin
            errs++;
            $display("CTRL CHIP TB FAIL: Memory output differs for global core (%0d,%0d)", gy, gx);
          end
        end
        $fclose(fd);
      end else begin
        dfd2 = $fopen({case_p, "/die_list.txt"}, "r");
        if (dfd2 == 0) $fatal(1, "cannot open %s/die_list.txt", case_p);
        while ($fgets(dln2, dfd2)) begin
          if ($sscanf(dln2, "%d %d", dr2, dc2) != 2) continue;
          fd = $fopen($sformatf("%s/die_%0d_%0d/core_list.txt", case_p, dr2, dc2), "r");
          if (fd == 0) continue;
          while ($fgets(line, fd)) begin
            int y, x, gfd;
            string gp, op;
            if ($sscanf(line, "%d %d", y, x) != 2) continue;
            gp = $sformatf("%s/die_%0d_%0d/%0d_%0d_mem_output.txt", case_p, dr2, dc2, y, x);
            gfd = $fopen(gp, "r");
            if (gfd == 0) continue;
            $fclose(gfd);
            op = $sformatf("out_d%0d_%0d_%0d_%0d.txt", dr2, dc2, y, x);
            core_mem_dump_md(dr2, dc2, y, x, gp, op);
            comparisons++;
            if ($system($sformatf(
                "env PYTHONIOENCODING=utf-8 python3 \"%s\" compare \"%s\" \"%s\" --mode memory",
                tj_py, gp, op)) == 0)
              $display("CTRL CHIP TB: golden comparison PASS (die (%0d,%0d) core (%0d,%0d))", dr2, dc2, y, x);
            else begin
              errs++;
              $display("CTRL CHIP TB FAIL: Memory output differs for die (%0d,%0d) core (%0d,%0d)", dr2, dc2, y, x);
            end
          end
          $fclose(fd);
        end
        $fclose(dfd2);
      end
`else
      foreach (cores[i]) begin
        int gfd;
        string gp, op;
        gp = $sformatf("%s/%0d_%0d_mem_output.txt", case_p, cores[i].y, cores[i].x);
        gfd = $fopen(gp, "r");
        if (gfd == 0) continue;
        $fclose(gfd);
        op = $sformatf("out_%0d_%0d.txt", cores[i].y, cores[i].x);
        core_mem_dump(cores[i].y, cores[i].x, gp, op);
        comparisons++;
        if ($system($sformatf(
            "env PYTHONIOENCODING=utf-8 python3 \"%s\" compare \"%s\" \"%s\" --mode memory",
            tj_py, gp, op)) == 0)
          $display("CTRL CHIP TB: golden comparison PASS (core %0d,%0d)", cores[i].y, cores[i].x);
        else begin
          errs++;
          $display("CTRL CHIP TB FAIL: memory output differs (core %0d,%0d)", cores[i].y, cores[i].x);
        end
      end
`endif
    end else if ($value$plusargs("TJ_GOLDEN=%s", golden_p) && $value$plusargs("TJ_OUT=%s", out_p)) begin
      gy = 0; gx = 0;
      void'($value$plusargs("TJ_GY=%d", gy));
      void'($value$plusargs("TJ_GX=%d", gx));
      if (gy < 0 || gy > 3 || gx < 0 || gx > 3) $fatal(1, "Invalid core coordinates");
      core_mem_dump(gy, gx, golden_p, out_p);
      comparisons++;
      if ($system($sformatf(
          "env PYTHONIOENCODING=utf-8 python3 \"%s\" compare \"%s\" \"%s\" --mode memory",
          tj_py, golden_p, out_p)) == 0)
        $display("CTRL CHIP TB: golden comparison PASS (core %0d,%0d)", gy, gx);
      else begin
        errs++;
        $display("CTRL CHIP TB FAIL: memory output differs (core %0d,%0d)", gy, gx);
      end
    end
    chk(comparisons > 0, "At least one output comparison ran");


    // Optional dx=-32 routing check.
    if (lvds_mode && $test$plusargs("TJ_DXTEST")) begin
      int hit;
      logic [127:0] r;
      apb_wr(16'h3C04, 32'h0);
      bounce_pkt(64'hD00D_FACE_CAFE_0001, hit);
      chk(hit >= 0, "dx=-32 packet returns through RECV");
      if (hit >= 0) begin
        r = last_bounce_rec;
        $display("CTRL CHIP TB: dx=-32 packet in ring %0d: pkt=%h, dx=%b", hit, r[95:0], r[17:12]);
        chk(r[95:32] == 64'hD00D_FACE_CAFE_0001, "Returned packet payload matches");
      end
      $display("CTRL CHIP TB: dx=-32 routing check complete");
    end

    // Optional link-error injection and W1C check.
    if (lvds_mode && $test$plusargs("TJ_ECCTEST")) begin
      int hit;
      // Disable auto-sleep and wake TX before injecting an error.
      apb_wr(16'h3C04, 32'h0);
      rdat = 32'h101; win_access(1'b1, 32'h01160400, rdat);
      rdat = 32'h210F;
      win_access(1'b1, 32'h01160004, rdat);
      win_access(1'b1, 32'h01160024, rdat);
      win_access(1'b1, 32'h01160044, rdat);
      rdat = 32'h0;   win_access(1'b1, 32'h01160400, rdat);
      bounce_pkt(64'hECC0_ECC0_ECC0_ECC0, hit);
      chk(hit >= 0, "Link wake-up packet returns through RECV");
      cc_write(25'h204, 32'hFFF);                   // Clear link errors after wake-up.
      cc_read(25'h204, rdat);
      chk(rdat === 32'h0, $sformatf("Link ERR_ST before injection=%08x, expected zero", rdat));
      // Inject an invalid 8b/10b symbol.
      force f_rxd_p[0] = 5'b00000;
      force f_rxd_n[0] = 5'b11111;
      #20ns;
      release f_rxd_p[0];
      release f_rxd_n[0];
      #1us;
      cc_read(25'h204, rdat);
      chk(rdat != 32'h0, $sformatf("Link ERR_ST after injection=%08x, expected nonzero", rdat));
      chk(rdat[0], $sformatf("RX0 decode error is set (ERR_ST=%08x)", rdat));
      $display("CTRL CHIP TB: Link ERR_ST after injection=%08x", rdat);
      cc_write(25'h204, 32'hFFF);
      cc_read(25'h204, rdat);
      chk(rdat === 32'h0, $sformatf("Link ERR_ST after W1C=%08x, expected zero", rdat));
      $display("CTRL CHIP TB: Link error injection and clearing complete");
    end

    if ($test$plusargs("TJ_BOOTSPI"))
      chk(boot_verified_cores == cores.size(),
          "All BOOT cores passed memory readback");

    if (errs == 0 && checks > 0) $display("CTRL CHIP TB PASS (%0d checks)", checks);
    else $fatal(1, "CTRL CHIP TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end

  initial begin
    #60ms;
    if ($test$plusargs("use_tj_ctrl")) begin
      $fatal(1, "CTRL CHIP TB TIMEOUT");
    end
  end
endmodule
