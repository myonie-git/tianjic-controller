// File        : tb_tj_spi_timeout.sv
// Module      : tb_tj_spi_timeout
// Description : SPI timeout recovery and subsequent chip access.
`timescale 1ns/1ps
module tb_tj_spi_timeout;
  logic clk = 0, hclk = 0, rst_n = 0;
  real pclk_hp = 5.0;
  int divider = 1;
  initial begin
    void'($value$plusargs("TJ_PCLK_HP=%f", pclk_hp));
    void'($value$plusargs("SPI_DIV=%d", divider));
    forever #(pclk_hp) clk = ~clk;
  end
  always #5 hclk = ~hclk;

  logic [7:0] cfg_clkdiv;
  logic [31:0] cfg_tmo, addr = 0, wdat = 0, rdat;
  logic cmd_valid = 0, cmd_ready, wdat_valid = 0, wdat_ready;
  logic rdat_valid, rdat_ready = 1, done, err_timeout, busy;
  logic [4:0] die_id = 0;
  logic [1:0] cmd_kind = 0;
  logic sclk, mosi;
  logic [3:0] cs_n, miso;
  tj_spi_engine #(.GRP(0)) dut (.*);

  logic [31:0] haddr, hwdata, hrdata;
  logic [1:0] htrans;
  logic hwrite, hready;
  assign miso[3:1] = 0;
  spi2ahb chip (
    .spi_cs_n(cs_n[0]), .spi_sck(sclk), .spi_mosi(mosi), .spi_miso(miso[0]),
    .hclk(hclk), .hresetn(rst_n), .hrdata(hrdata), .hready(hready), .hresp(1'b0),
    .haddr(haddr), .hwdata(hwdata), .htrans(htrans), .hwrite(hwrite),
    .hburst(), .hsize(), .hprot(), .hmastlock()
  );

  // AHB RAM with four wait states per transfer; no DUT hierarchy access.
  logic [31:0] mem[0:1023];
  logic pending = 0, pending_write = 0;
  logic [31:0] pending_addr = 0;
  int wait_left = 0;
  assign hready = wait_left == 0;
  assign hrdata = pending ? mem[pending_addr[11:2]] : 0;
  always @(posedge hclk or negedge rst_n) begin
    if (!rst_n) begin
      pending <= 0;
      pending_write <= 0;
      pending_addr <= 0;
      wait_left <= 0;
      for (int n = 0; n < 1024; n++) mem[n] <= 32'hCAFE0000 + n;
    end else if (hready) begin
      if (pending && pending_write) mem[pending_addr[11:2]] <= hwdata;
      pending <= htrans[1];
      pending_write <= hwrite;
      pending_addr <= haddr;
      if (htrans[1]) wait_left <= 4;
    end else wait_left <= wait_left - 1;
  end

  int checks = 0, errs = 0, done_count = 0, err_count = 0, read_count = 0;
  int handshakes = 0, frames = 0, frames_at_error = 0;
  logic [31:0] last_read;
  bit guard_active = 0, premature_idle = 0;
  real last_release = -1, error_delay = -1, recovery_gap = -1;
  string phase = "reset";

  always @(posedge clk) if (rst_n) begin
    if (cmd_valid && cmd_ready) handshakes++;
    if (rdat_valid && rdat_ready) begin read_count++; last_read = rdat; end
    if (done) done_count++;
    if (err_timeout) begin err_count++; frames_at_error = frames; end
    if (guard_active && err_count == 0 && !err_timeout && (!busy || cmd_ready))
      premature_idle = 1;
  end
  always @(posedge cs_n[0]) if (rst_n) last_release = $realtime;
  always @(negedge cs_n[0]) if (rst_n) begin
    frames++;
    if (err_count != 0 && recovery_gap < 0) recovery_gap = $realtime-last_release;
  end
  always @(posedge err_timeout) if (rst_n) begin
    // CS and ERR can rise on the same edge in the unfixed implementation.
    #0.001;
    error_delay = $realtime-last_release-0.001;
  end

  task automatic chk(input logic ok, input string label);
    checks++;
    if (ok !== 1'b1) begin
      errs++;
      $display("FAIL: %s: %s @%0t", phase, label, $time);
    end
  endtask
  task automatic reset_case(input string name);
    @(negedge clk);
    rst_n = 0; guard_active = 0; cmd_valid = 0; wdat_valid = 0;
    repeat (10) @(negedge clk);
    done_count = 0; err_count = 0; read_count = 0; handshakes = 0;
    frames = 0; frames_at_error = 0; premature_idle = 0;
    last_release = -1; error_delay = -1; recovery_gap = -1;
    cfg_clkdiv = 8'(divider); cfg_tmo = 0; phase = name;
    rst_n = 1;
    repeat (5) @(negedge clk);
  endtask
  task automatic command(input logic [1:0] kind, input logic [31:0] address,
                         input int timeout_cycles);
    @(negedge clk);
    cfg_clkdiv = 8'(divider); cfg_tmo = timeout_cycles;
    cmd_kind = kind; addr = address; cmd_valid = 1;
    do @(posedge clk); while (!cmd_ready);
    @(negedge clk); cmd_valid = 0;
  endtask
  task automatic send_word(input logic [31:0] value);
    @(negedge clk); wdat = value; wdat_valid = 1;
    do @(posedge clk); while (!wdat_ready);
    @(negedge clk); wdat_valid = 0;
  endtask
  task automatic wait_done(input int expected_count);
    while (done_count < expected_count) @(negedge clk);
  endtask
  task automatic abort_then_access(input string name, input logic [1:0] kind,
                                   input int timeout_cycles, input int supplied_words,
                                   input int expected_frames, input real min_high_ns);
    int reads_before;
    reset_case(name);
    command(kind, 32'h200, timeout_cycles);
    guard_active = 1;
    for (int n = 0; n < supplied_words; n++) send_word(32'hBAD00000+n);
    // Queue the next command immediately, but supply its data only after acceptance.
    command(0, 32'h400, 100000);
    guard_active = 0;
    chk(err_count == 1 && done_count == 0, "Aborted command reports exactly one error");
    chk(!premature_idle, "BUSY stays set and READY stays low until the error");
    chk(frames_at_error == expected_frames, "Timeout occurred in the intended frame");
    chk(error_delay >= min_high_ns-0.01, "CS high interval completes before error reporting");
    send_word(32'hACCE5510);
    wait_done(1);
    repeat (12) @(negedge hclk);
    chk(recovery_gap >= min_high_ns, "Next SPI frame observes the recovery interval");
    chk(mem[256] == 32'hACCE5510, "Following WR1 reaches the chip memory");
    reads_before = read_count;
    command(2, 32'h400, 100000);
    wait_done(2);
    chk(read_count == reads_before+1 && last_read == 32'hACCE5510,
        "Following RD1 returns the written value");
    chk(err_count == 1 && handshakes == 3, "No duplicate errors or command acceptance");
    chk(!busy && cmd_ready && cs_n == 4'hF && !sclk, "Engine returns to idle");
    $display("%s: error_delay=%0.1f ns next_frame_gap=%0.1f ns",name,error_delay,recovery_gap);
  endtask

  initial begin
    cfg_clkdiv = 1; cfg_tmo = 0;
    // P1: ordinary write and read timeouts, followed by a queued write.
    abort_then_access("P1 WR1", 0, 100, 0, 1, 40.0);
    abort_then_access("P1 RD1", 2, 100, 0, 1, 40.0);
    // P2: write source stalls after four words; the chip still starts an INCR16 burst.
    abort_then_access("P2 WR16", 1, 4000, 4, 1, 1000.0);
    // P3: RD16 has completed its request frame and is waiting for the AHB burst.
    abort_then_access("P3 RDREQ16", 3, 40*2*(divider+1)+50, 0, 1, 1000.0);
    // P4: abort the fetch frame after it has started returning data.
    abort_then_access("P4 RD16 fetch", 3, 112*2*(divider+1)+456, 0, 2, 40.0);
    if (checks > 0 && errs == 0) $display("SPI TIMEOUT TB PASS (%0d checks)",checks);
    else $display("SPI TIMEOUT TB FAIL (%0d/%0d checks)",errs,checks);
    $finish;
  end
  initial begin #10000000; $fatal(1,"SPI TIMEOUT TB TIMEOUT"); end
endmodule
