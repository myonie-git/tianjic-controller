// File        : tb_tj_spi_status.sv
// Module      : tb_tj_spi_status
// Description : Check SPI doorbell status through APB and GO rejection through module ports.

module tb_tj_spi_status;
  import tj_ctrl_pkg::*;
  import tj_ctrl_csr_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
  logic [15:0] paddr = '0;
  logic [31:0] pwdata = '0, prdata;
  logic pready, pslverr;
  tj_csr_i_t hwi;
  tj_csr_o_t hwo;
  logic [7:0][31:0] spi_rdata;
  logic [7:0] spi_busy, eng_busy, spi_done, spi_err;
  logic spiwin_busy, spiwin_err;

  tj_ctrl_csr u_csr (
    .pclk(clk), .presetn(rst_n), .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata), .pready(pready), .pslverr(pslverr), .prdata(prdata),
    .hwi(hwi), .hwo(hwo)
  );

  tj_spi_subsys u_spi (
    .pclk(clk), .presetn(rst_n), .hwo(hwo),
    .spi_rdata_o(spi_rdata), .spi_busy_o(spi_busy), .eng_busy_o(eng_busy),
    .spi_done_set_o(spi_done), .spi_err_set_o(spi_err),
    .spiwin_busy_o(spiwin_busy), .spiwin_err_set_o(spiwin_err),
    .win_psel(1'b0), .win_penable(1'b0), .win_pwrite(1'b0),
    .win_paddr(12'h0), .win_pwdata(32'h0),
    .win_pready(), .win_pslverr(), .win_prdata(),
    .spi_sclk(), .spi_mosi(), .spi_cs_n(), .spi_miso(32'h0)
  );

  always_comb begin
    hwi = '0;
    hwi.spi_rdata              = spi_rdata;
    hwi.spi_sta_busy           = spi_busy;
    hwi.spi_sta_done_set       = spi_done;
    hwi.spi_sta_err_tmo_set    = spi_err;
    hwi.spiwin_sta_busy        = spiwin_busy;
    hwi.spiwin_sta_err_tmo_set = spiwin_err;
    hwi.glb_sta_spi_busy       = eng_busy;
  end

  // Drive the terminal-cycle GO directly, without relying on SPI transfer duration.
  logic db_rst_n = 1'b0, db_go = 1'b0, db_done = 1'b0, db_err = 1'b0;
  logic db_busy, db_cmd_valid, db_done_set, db_err_set;

  tj_spi_doorbell u_doorbell (
    .clk(clk), .rst_n(db_rst_n), .db_go(db_go),
    .csr_kind(2'd0), .csr_die(2'd0), .csr_addr(32'h1000),
    .csr_wdata(32'h12345678), .grp_id(3'd0),
    .rdata_o(), .busy_o(db_busy), .done_set_o(db_done_set), .err_set_o(db_err_set),
    .cmd_valid(db_cmd_valid), .cmd_ready(1'b1), .die_id(), .cmd_kind(), .addr(),
    .wdat_valid(), .wdat_ready(1'b1), .wdat(),
    .rdat_valid(1'b0), .rdat_ready(), .rdat(32'h0),
    .done(db_done), .err_timeout(db_err)
  );

  int checks = 0;
  int errs = 0;
  task automatic chk(input logic condition, input string message);
    checks++;
    if (condition !== 1'b1) begin
      errs++;
      $display("FAIL: %s @%0t", message, $time);
    end
  endtask

  // Drive APB on falling edges and sample at the access completion edge, before NBA updates.
  task automatic apb_xfer(input bit write_en, input logic [15:0] address,
                          input logic [31:0] data, output logic [31:0] result);
    @(negedge clk);
    psel = 1'b1;
    penable = 1'b0;
    pwrite = write_en;
    paddr = address;
    pwdata = data;
    @(negedge clk);
    penable = 1'b1;
    @(posedge clk);
    chk(pready && !pslverr, "APB zero-wait access");
    result = prdata;
  endtask

  task automatic apb_write(input logic [15:0] address, input logic [31:0] data);
    logic [31:0] unused;
    apb_xfer(1'b1, address, data, unused);
  endtask

  task automatic apb_idle(input int cycles);
    repeat (cycles) begin
      @(negedge clk);
      psel = 1'b0;
      penable = 1'b0;
    end
  endtask

  localparam logic [15:0] A_CMD = 16'h0400, A_ADDR = 16'h0404, A_WDATA = 16'h0408,
                          A_CLKDIV = 16'h0410, A_TMO = 16'h0414,
                          A_DB = 16'h0418, A_STA = 16'h041C;

  task automatic check_status(input string name, input logic [1:0] kind,
                               input bit expect_timeout, input int phase);
    logic [31:0] status;
    int reads;
    reads = 0;
    apb_write(A_TMO, expect_timeout ? 32'd40 : 32'd100000);
    apb_write(A_STA, 32'h300);
    apb_write(A_CMD, {30'h0, kind});
    apb_write(A_ADDR, 32'h1000);
    apb_write(A_WDATA, 32'h12345678);
    apb_write(A_DB, 32'h1);
    apb_idle(phase);
    forever begin
      apb_xfer(1'b0, A_STA, '0, status);
      reads++;
      chk(status[0] || status[8] || status[9],
          $sformatf("%s phase=%0d: BUSY/DONE/ERR all zero", name, phase));
      if (status[8] || status[9]) begin
        chk(!status[0], "BUSY clears when result is visible");
        chk({status[9], status[8]} == (expect_timeout ? 2'b10 : 2'b01),
            "Expected completion result");
        break;
      end
      if (reads >= 5000) begin
        chk(1'b0, "Status polling timeout");
        break;
      end
    end
    apb_idle(4);
  endtask

  task automatic check_busy_go(input bit timeout_case);
    db_rst_n = 1'b0;
    db_go = 1'b0;
    db_done = 1'b0;
    db_err = 1'b0;
    repeat (2) @(negedge clk);
    db_rst_n = 1'b1;
    @(negedge clk); db_go = 1'b1;
    @(negedge clk); db_go = 1'b0;
    chk(db_busy && db_cmd_valid, "Idle GO starts a command");
    repeat (2) @(negedge clk);

    // GO is ignored while a transfer is active.
    chk(db_busy, "Doorbell busy before terminal event");
    db_go = 1'b1;
    @(negedge clk); db_go = 1'b0;
    chk(db_busy && !db_cmd_valid, "Active transfer ignores GO");

    db_done = !timeout_case;
    db_err = timeout_case;
    @(negedge clk);
    db_done = 1'b0;
    db_err = 1'b0;
    chk({db_err_set, db_done_set} == (timeout_case ? 2'b10 : 2'b01),
        "Terminal event pulse");
    chk(db_busy, "BUSY covers the pending CSR event");
    db_go = 1'b1;
    @(negedge clk); db_go = 1'b0;
    chk(!db_cmd_valid, "Terminal busy cycle ignores GO");
    chk(!db_busy && !db_done_set && !db_err_set, "Return idle after event delivery");

    // A fresh GO after BUSY clears must still work.
    @(negedge clk); db_go = 1'b1;
    @(negedge clk); db_go = 1'b0;
    chk(db_busy && db_cmd_valid, "Next idle GO starts a command");
    db_rst_n = 1'b0;
  endtask

  initial begin
    repeat (5) @(negedge clk);
    rst_n = 1'b1;

    // P1: GO handling during execution and completion/error reporting.
    check_busy_go(1'b0);
    check_busy_go(1'b1);

    // P2: Poll CSR at both phases of consecutive two-cycle APB reads.
    apb_write(A_CLKDIV, 32'd1);
    for (int phase = 0; phase < 2; phase++) begin
      check_status("WR1", 2'd0, 1'b0, phase);
      check_status("RD1", 2'd1, 1'b0, phase);
      check_status("TIMEOUT", 2'd0, 1'b1, phase);
      check_status("KIND2", 2'd2, 1'b0, phase);
    end

    if (checks > 0 && errs == 0) $display("SPI STATUS TB PASS (%0d checks)", checks);
    else $display("SPI STATUS TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end

  initial begin
    #1000000;
    $fatal(1, "SPI STATUS TB TIMEOUT");
  end
endmodule
