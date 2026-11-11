// File        : tb_tj_ctrl_apb_smoke.sv
// Module      : tb_tj_ctrl_apb_smoke
// Description : Basic APB and reset-output checks for tj_ctrl_top.
//               Run after compiling Controller and chip RTL into one library.
module tb_tj_ctrl_apb_smoke;
  timeunit 1ns;
  timeprecision 1ps;
  import tj_ctrl_csr_pkg::*;

  logic pclk = 0, presetn = 0, maxi_clk = 0, maxi_rstn = 0;
  always #5   pclk = ~pclk;         // 100 MHz.
  always #3.7 maxi_clk = ~maxi_clk;  // 135.1 MHz.

  logic psel, penable, pwrite;
  logic [15:0] paddr;
  logic [31:0] pwdata, prdata;
  logic pready, pslverr;
  logic [3:0] irq;
  logic [31:0] chip_rst_n;
  logic [3:0] clkctl;

  tj_ctrl_top u_dut (
    .pclk, .presetn, .maxi_clk, .maxi_rstn,
    .psel, .penable, .pwrite, .paddr, .pwdata, .pready, .pslverr, .prdata,
    .awvalid(), .awready(1'b0), .awid(), .awaddr(), .awuser(), .awlen(), .awsize(), .awburst(),
    .wvalid(), .wready(1'b0), .wdata(), .wstrb(), .wlast(),
    .bvalid(1'b0), .bready(), .bresp(2'b0), .bid('0),
    .arvalid(), .arready(1'b0), .arid(), .araddr(), .aruser(), .arlen(), .arsize(), .arburst(),
    .rvalid(1'b0), .rready(), .rdata('0), .rresp(2'b0), .rlast(1'b0), .rid('0),
    .s_axis_pk_tvalid(1'b0), .s_axis_pk_tready(), .s_axis_pk_tdata('0), .s_axis_pk_tlast(1'b0),
    .m_axis_pk_tvalid(), .m_axis_pk_tready(1'b0), .m_axis_pk_tdata(), .m_axis_pk_tlast(),
    .irq(irq),
    .lv_tx_tvalid(), .lv_tx_tready('0), .lv_tx_tdata(),
    .lv_rx_tvalid('0), .lv_rx_tready(), .lv_rx_tdata('0),
    .lvcfg_din(), .lvcfg_din_vld(), .lvcfg_dout('0), .lvcfg_dout_vld('0),
    .spi_sclk(), .spi_mosi(), .spi_cs_n(), .spi_miso('0),
    .chip_rst_n(chip_rst_n), .clkctl(clkctl),
    .uart_rx(1'b1), .uart_tx()
  );

  int errs = 0;
  int checks = 0;
  logic [31:0] rd;

  task automatic chk(input bit ok, input string msg);
    checks++;
    if (!ok) begin
      errs++;
      $display("CTRL APB SMOKE TB FAIL: %s", msg);
    end
  endtask

  // APB accesses use only public top-level ports.
  task automatic apb_rd(input [15:0] a, output [31:0] d);
    @(posedge pclk);
    psel <= 1;
    penable <= 0;
    pwrite <= 0;
    paddr <= a;
    @(posedge pclk); penable <= 1;
    @(posedge pclk);
    while (!pready) @(posedge pclk);
    chk(pready === 1'b1, $sformatf("APB read PREADY at %04h", a));
    chk(pslverr === 1'b0, $sformatf("APB read PSLVERR at %04h", a));
    d = prdata;
    psel <= 0;
    penable <= 0;
    @(posedge pclk);
  endtask

  task automatic apb_wr(input [15:0] a, input [31:0] d);
    @(posedge pclk);
    psel <= 1;
    penable <= 0;
    pwrite <= 1;
    paddr <= a;
    pwdata <= d;
    @(posedge pclk); penable <= 1;
    @(posedge pclk);
    while (!pready) @(posedge pclk);
    chk(pready === 1'b1, $sformatf("APB write PREADY at %04h", a));
    chk(pslverr === 1'b0, $sformatf("APB write PSLVERR at %04h", a));
    psel <= 0;
    penable <= 0;
    @(posedge pclk);
  endtask

  initial begin
    psel = 0;
    penable = 0;
    pwrite = 0;
    paddr = '0;
    pwdata = '0;
    repeat (5) @(posedge pclk);
    @(negedge pclk);
    presetn = 1;
    maxi_rstn = 1;
    repeat (5) @(posedge pclk);

    chk(chip_rst_n === 32'h0, "Reset outputs default low");
    apb_rd(16'h0000, rd);
    chk(rd === 32'h544A4331, "Controller ID");

    apb_wr(16'h0008, 32'hE0E0_5A5A);
    apb_rd(16'h0008, rd);
    chk(rd === 32'hE0E0_5A5A, "SCRATCH readback");

    apb_wr(16'h0200, 32'h0000_0003);  // Release die 0 and die 1.
    repeat (2) @(posedge pclk);
    chk(chip_rst_n === 32'h3, "RST_LEVEL reaches reset outputs");
    apb_wr(16'h0200, 32'h0);
    repeat (2) @(posedge pclk);
    chk(chip_rst_n === 32'h0, "RST_LEVEL reasserts reset outputs");

    // The generated CSR selects SPI and RECV dimensions without global macros.
    apb_rd(16'h0004, rd);
    chk(rd === (TJ_CSR_SPI_N == 4 ? 32'h200 : 32'h100), "Profile VERSION");
    for (int g=0; g<TJ_CSR_SPI_N; g++) begin
      apb_wr(16'(16'h0400 + g*16'h80), 32'h70);
      apb_rd(16'(16'h0400 + g*16'h80), rd);
      chk(rd === (TJ_CSR_SPI_N == 4 ? 32'h70 : 32'h30), "SPI.CMD.DIE width");
    end

    if (errs == 0 && checks > 0)
      $display("CTRL APB SMOKE TB PASS (%0d checks)", checks);
    else
      $fatal(1, "CTRL APB SMOKE TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end

  initial begin
    #1ms;
    $fatal(1, "CTRL APB SMOKE TB TIMEOUT");
  end
endmodule
