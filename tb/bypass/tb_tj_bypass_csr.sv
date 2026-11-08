// File        : tb_tj_bypass_csr.sv
// Module      : tb_tj_bypass_csr
// Description : SPI bypass accesses to the generated Controller CSR block.
`timescale 1ns/1ps

module tb_tj_bypass_csr;
  `include "tj_case_select.svh"
  import tj_ctrl_csr_pkg::*;

  localparam int unsigned APB_AW = 16;

  logic pclk = 1'b0;
  always #2.5 pclk = ~pclk;          // 200MHz
  logic presetn = 1'b0;

  logic sclk = 1'b0, mosi = 1'b0, ss_n = 1'b1;
  logic miso, miso_oe;
  real  sclk_hp = 25.0;

  // Downstream CSR interface.
  logic              psel, penable, pwrite;
  logic [15:0]       paddr;
  logic [31:0]       pwdata;
  logic              pready, pslverr;
  logic [31:0]       prdata;
  tj_csr_i_t hwi;
  tj_csr_o_t hwo;

  tj_bypass_spi #(.APB_AW(APB_AW), .ENABLE_BYPASS_SPI(1'b1)) u_dut (
    .pclk, .presetn,
    .spi_sclk(sclk), .spi_mosi(mosi), .spi_ss_n(ss_n),
    .spi_miso(miso), .spi_miso_oe(miso_oe),
    .u_psel(1'b0), .u_penable(1'b0), .u_pwrite(1'b0),
    .u_paddr('0), .u_pwdata('0),
    .u_pready(), .u_pslverr(), .u_prdata(),
    .d_psel(psel), .d_penable(penable), .d_pwrite(pwrite),
    .d_paddr(paddr), .d_pwdata(pwdata),
    .d_pready(pready), .d_pslverr(pslverr), .d_prdata(prdata)
  );

  tj_ctrl_csr u_csr (
    .pclk, .presetn,
    .psel, .penable, .pwrite, .paddr, .pwdata,
    .pready, .pslverr, .prdata,
    .hwi, .hwo
  );

  // Test results.
  int unsigned n_chk = 0, n_err = 0;
  task automatic chk(input bit cond, input string msg);
    n_chk++;
    if (!cond) begin
      n_err++;
      $display("[%0t] FAIL: %s", $time, msg);
    end
  endtask

  // SPI host transactions.
  task automatic spi_open();  ss_n = 1'b0; #(50.0); endtask
  task automatic spi_close(); #(50.0); ss_n = 1'b1; mosi = 1'b0; #(100.0); endtask
  task automatic spi_byte(input logic [7:0] tx, output logic [7:0] rx);
    for (int i = 7; i >= 0; i--) begin
      mosi = tx[i];
      #(sclk_hp);
      rx[i] = miso;
      sclk = 1'b1;
      #(sclk_hp);
      sclk = 1'b0;
    end
  endtask

  task automatic wr1(input logic [15:0] a, input logic [31:0] d,
                     output logic [7:0] last_st);
    logic [7:0] r;
    spi_open();
    spi_byte(8'h00, r);  chk(r == 8'hA5, "wr1 alive");
    spi_byte(8'h00, r);
    spi_byte(8'h00, r);
    spi_byte(a[15:8], r);
    spi_byte(a[7:0],  r);
    for (int b = 3; b >= 0; b--) spi_byte(d[8*b +: 8], r);
    // The second status byte reflects the completed APB write.
    spi_byte(8'h00, r);
    spi_byte(8'h00, r);
    last_st = r;
    spi_close();
  endtask

  task automatic rdn(input logic [15:0] a, input int n,
                     output logic [31:0] data []);
    logic [7:0] r;
    logic [7:0] cmd = {1'b1, (n > 1), 6'(n - 1)};
    data = new[n];
    spi_open();
    spi_byte(cmd, r);  chk(r == 8'hA5, "rdn alive");
    spi_byte(8'h00, r); spi_byte(8'h00, r);
    spi_byte(a[15:8], r); spi_byte(a[7:0], r);
    spi_byte(8'h00, r); spi_byte(8'h00, r);
    for (int w = 0; w < n; w++)
      for (int b = 3; b >= 0; b--) begin
        spi_byte(8'h00, r);
        data[w][8*b +: 8] = r;
      end
    spi_close();
  endtask

  // Test sequence.
  logic [31:0] rbuf [];
  logic [7:0]  st;
  logic [31:0] id_q;

  initial begin : main
    tj_cases_init("C1,C2,C3,C4,C5,C6,C7");
    $timeformat(-9, 1, "ns", 10);
    hwi = '0;
    presetn = 1'b0;
    repeat (10) @(posedge pclk);
    presetn = 1'b1;
    repeat (10) @(posedge pclk);

    // C1: Read ID and VERSION in one burst.
    if (tj_run_case("C1")) begin
      $display("== C1 ID/VERSION");
      rdn(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_ID), 2, rbuf);
      chk(rbuf[0] == 32'h544A_4331, $sformatf("C1 ID got %08x", rbuf[0]));
      id_q = rbuf[0];
      chk(rbuf[1] == 32'h0000_0100, $sformatf("C1 VERSION got %08x", rbuf[1]));
    end

    // C2: Write and read three SCRATCH patterns.
    if (tj_run_case("C2")) begin
      $display("== C2 SCRATCH");
      begin
        logic [31:0] pat [3] = '{32'hFFFF_FFFF, 32'h0000_0000, 32'hA5A5_A5A5};
        for (int i = 0; i < 3; i++) begin
          wr1(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_SCRATCH), pat[i], st);
          chk(st == 8'h00, $sformatf("C2 st%0d", i));
          rdn(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_SCRATCH), 1, rbuf);
          chk(rbuf[0] == pat[i], $sformatf("C2 rb%0d got %08x", i, rbuf[0]));
        end
      end
    end

    // C3: Set IRQ events through hwi, then clear selected bits through SPI.
    if (tj_run_case("C3")) begin
      $display("== C3 W1C");
      @(posedge pclk); hwi.irq_raw_set <= 32'h0000_0500;
      @(posedge pclk); hwi.irq_raw_set <= '0;
      rdn(16'(TJ_CSR_IRQ_BASE + TJ_CSR_IRQ_RAW), 1, rbuf);
      chk(rbuf[0] == 32'h0000_0500, $sformatf("C3 raw set got %08x", rbuf[0]));
      wr1(16'(TJ_CSR_IRQ_BASE + TJ_CSR_IRQ_RAW), 32'h0000_0400, st);
      chk(st == 8'h00, "C3 w1c st");
      rdn(16'(TJ_CSR_IRQ_BASE + TJ_CSR_IRQ_RAW), 1, rbuf);
      chk(rbuf[0] == 32'h0000_0100, $sformatf("C3 raw after w1c got %08x", rbuf[0]));
      wr1(16'(TJ_CSR_IRQ_BASE + TJ_CSR_IRQ_RAW), 32'h0000_0100, st);
    end

    // C4: Return 0xEE for unmapped addresses; clear errors in the next frame.
    if (tj_run_case("C4")) begin
      if (tj_case_filter_active)
        wr1(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_SCRATCH), 32'hA5A5_A5A5, st);
      $display("== C4 unmapped pslverr");
      wr1(16'h5000, 32'h1234_5678, st);
      chk(st == 8'hEE, $sformatf("C4 wr unmapped st got %02x", st));
      rdn(16'h5000, 1, rbuf);
      chk(rbuf[0] == 32'hEEEE_EEEE, $sformatf("C4 rd unmapped got %08x", rbuf[0]));
      rdn(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_SCRATCH), 1, rbuf);
      chk(rbuf[0] == 32'hA5A5_A5A5, "C4 next frame clean");
    end

    // C5: Ignore writes to read-only registers without reporting an error.
    if (tj_run_case("C5")) begin
      if (tj_case_filter_active) begin
        rdn(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_ID), 1, rbuf);
        id_q = rbuf[0];
      end
      $display("== C5 RO write-ignore");
      wr1(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_ID), 32'hDEAD_BEEF, st);
      chk(st == 8'h00, "C5 st(RO write no err)");
      rdn(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_ID), 1, rbuf);
      chk(rbuf[0] == id_q, $sformatf("C5 ID unchanged got %08x", rbuf[0]));
    end

    // C6: Read distinct RAW, EN, STA and TST values in one burst.
    if (tj_run_case("C6")) begin
      $display("== C6 burst on zero-wait slave");
      @(negedge pclk); hwi.irq_raw_set = 32'h0000_0500;
      @(negedge pclk); hwi.irq_raw_set = '0;
      wr1(16'(TJ_CSR_IRQ_BASE + TJ_CSR_IRQ_EN), 32'h0000_0C00, st);
      chk(st == 8'h00, "C6 EN write status");
      rdn(16'(TJ_CSR_IRQ_BASE), 4, rbuf);
      chk(rbuf[0] == 32'h0000_0500, $sformatf("C6 RAW got %08x", rbuf[0]));
      chk(rbuf[1] == 32'h0000_0C00, $sformatf("C6 EN got %08x", rbuf[1]));
      chk(rbuf[2] == 32'h0000_0400, $sformatf("C6 STA got %08x", rbuf[2]));
      chk(rbuf[3] == 32'h0000_0000, $sformatf("C6 TST got %08x", rbuf[3]));
    end

    // C7: Run at SCLK = pclk/8.
    if (tj_run_case("C7")) begin
      $display("== C7 SCLK=pclk/8");
      sclk_hp = 20.0;
      wr1(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_SCRATCH), 32'h5A5A_1234, st);
      chk(st == 8'h00, "C7 st");
      rdn(16'(TJ_CSR_GLB_BASE + TJ_CSR_GLB_SCRATCH), 1, rbuf);
      chk(rbuf[0] == 32'h5A5A_1234, $sformatf("C7 rb got %08x", rbuf[0]));
    end

    if (n_err == 0) $display("BYPASS CSR TB PASS (%0d checks)", n_chk);
    else            $display("BYPASS CSR TB FAIL (%0d errors / %0d checks)", n_err, n_chk);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("BYPASS CSR TB TIMEOUT");
    $finish;
  end

endmodule
