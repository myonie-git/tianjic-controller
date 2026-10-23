// File        : tb_tj_spi_arb2.sv
// Module      : tb_tj_spi_arb2
// Description : Check SPI arbitration, same-cycle continuation, and ownership release.

module tb_tj_spi_arb2;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // Source 0 is A; source 1 is B.
  logic [1:0] cv, cr, wv, wr, rv, rr, done, err;
  logic [1:0][4:0] die;
  logic [1:0][1:0] kind;
  logic [1:0][31:0] addr, wd;
  logic ecv, ecr, ewv, ewr, erv, errdy, edone, eerr;
  logic [4:0] edie;
  logic [1:0] ekind;
  logic [31:0] eaddr, ewd, erd, rbus;
  int checks = 0;
  int errs = 0;

  tj_spi_arb2 dut (
    .clk(clk), .rst_n(rst_n),
    .a_cmd_valid(cv[0]), .a_cmd_ready(cr[0]), .a_die(die[0]),
    .a_kind(kind[0]), .a_addr(addr[0]), .a_wdat_valid(wv[0]),
    .a_wdat_ready(wr[0]), .a_wdat(wd[0]), .a_rdat_valid(rv[0]),
    .a_rdat_ready(rr[0]), .a_done(done[0]), .a_err(err[0]),
    .b_cmd_valid(cv[1]), .b_cmd_ready(cr[1]), .b_die(die[1]),
    .b_kind(kind[1]), .b_addr(addr[1]), .b_wdat_valid(wv[1]),
    .b_wdat_ready(wr[1]), .b_wdat(wd[1]), .b_rdat_valid(rv[1]),
    .b_rdat_ready(rr[1]), .b_done(done[1]), .b_err(err[1]),
    .e_cmd_valid(ecv), .e_cmd_ready(ecr), .e_die(edie), .e_kind(ekind),
    .e_addr(eaddr), .e_wdat_valid(ewv), .e_wdat_ready(ewr), .e_wdat(ewd),
    .e_rdat_valid(erv), .e_rdat_ready(errdy), .e_rdat(erd),
    .e_done(edone), .e_err(eerr), .rdat_bus(rbus)
  );

  task automatic chk(input logic condition, input string message);
    checks++;
    if (condition !== 1'b1) begin
      errs++;
      $display("FAIL: %s @%0t", message, $time);
    end
  endtask

  task automatic step;
    @(posedge clk); #1;
  endtask

  task automatic reset_dut;
    rst_n = 0;
    cv = 0; wv = 0; rr = 2'b11;
    ecr = 1; ewr = 0; erv = 0; edone = 0; eerr = 0; erd = 0;
    die[0] = 5'd1; die[1] = 5'd2;
    kind = '0;
    addr[0] = 32'h1000; addr[1] = 32'h2000;
    wd[0] = 32'hA5A5_1111; wd[1] = 32'h5A5A_2222;
    repeat (2) @(negedge clk);
    rst_n = 1;
    #1;
  endtask

  task automatic start_write(input bit owner);
    logic [1:0] mask;
    mask = owner ? 2'b10 : 2'b01;
    @(negedge clk); cv[owner] = 1;
    #1;
    chk(ecv && cr == mask, "Initial command handshake");
    step();
    @(negedge clk); cv[owner] = 0; ecr = 0; wv[owner] = 1; ewr = 1;
    #1;
    chk(ewv && wr == mask && ewd == wd[owner], "Initial write data route");
    step();
    @(negedge clk); wv = 0; ewr = 0;
  endtask

  task automatic continuation(input bit owner, input bit timeout_case, input bit next_read);
    logic [1:0] mask, peer_mask;
    string name;
    mask = owner ? 2'b10 : 2'b01;
    peer_mask = mask ^ 2'b11;
    name = $sformatf("owner=%0d timeout=%0d read=%0d", owner, timeout_case, next_read);
    reset_dut();
    start_write(owner);

    // The other source waits while the current owner submits its next command.
    @(negedge clk);
    cv = 2'b11;
    kind[owner] = next_read ? 2'd2 : 2'd0;
    addr[owner] = 32'h3000;
    wd[owner] = 32'hC001_CAFE;
    edone = !timeout_case;
    eerr = timeout_case;
    ecr = 1;
    #1;
    chk(ecv && cr == mask && eaddr == 32'h3000 && ekind == kind[owner],
        {name, ": next command accepted with terminal event"});
    chk(done == (timeout_case ? 2'b00 : mask) && err == (timeout_case ? mask : 2'b00),
        {name, ": old result belongs to current owner"});
    @(posedge clk);
    cv[owner] <= 0;
    edone <= 0;
    eerr <= 0;
    ecr <= 0;
    #1;
    chk(!ecv && done == 0 && err == 0, {name, ": ownership retained after continuation"});

    @(negedge clk);
    if (next_read) begin
      erv = 1;
      erd = 32'h89AB_CDEF;
      #1;
      chk(rv == mask && rbus == 32'h89AB_CDEF && errdy,
          {name, ": continued read returns to owner"});
    end else begin
      wv[owner] = 1;
      ewr = 1;
      #1;
      chk(ewv && ewd == 32'hC001_CAFE && wr == mask,
          {name, ": continued write data reaches engine"});
    end
    step();
    @(negedge clk); wv = 0; ewr = 0; erv = 0;

    // With no new command from this owner, completion/error must release the engine.
    edone = !timeout_case;
    eerr = timeout_case;
    ecr = 1;
    #1;
    chk(!ecv && done == (timeout_case ? 2'b00 : mask) &&
        err == (timeout_case ? mask : 2'b00), {name, ": continued result returns to owner"});
    @(posedge clk); edone <= 0; eerr <= 0;
    #1;
    chk(ecv && cr == peer_mask, {name, ": peer becomes eligible after release"});
    chk(done == 0 && err == 0, {name, ": no old result leaks to peer"});
    step();
    @(negedge clk); cv[!owner] = 0; ecr = 0; wv[!owner] = 1; ewr = 1;
    #1;
    chk(ewv && wr == peer_mask && ewd == wd[!owner],
        {name, ": peer write works after completion or timeout"});
  endtask

  initial begin
    reset_dut();
    // P1: Fixed priority and transaction ownership.
    @(negedge clk); cv = 2'b11;
    #1;
    chk(ecv && cr == 2'b01 && eaddr == 32'h1000, "A wins simultaneous idle requests");
    step();
    @(negedge clk); cv[0] = 0; ecr = 0;
    #1;
    chk(!ecv && cr == 0, "Waiting B cannot preempt A");

    // P2: Both owners, both terminal events, and both next-transfer directions.
    for (int owner = 0; owner < 2; owner++)
      for (int timeout_case = 0; timeout_case < 2; timeout_case++)
        for (int next_read = 0; next_read < 2; next_read++)
          continuation(1'(owner), 1'(timeout_case), 1'(next_read));

    // P3: A valid command without READY must not count as an accepted continuation.
    reset_dut();
    start_write(1'b1);
    @(negedge clk); cv = 2'b11; ecr = 0; eerr = 1;
    #1;
    chk(ecv && cr == 0 && eaddr == 32'h2000, "No new handshake while READY is low");
    @(posedge clk); eerr <= 0;
    #1;
    chk(ecv && eaddr == 32'h1000 && err == 0,
        "Release B on timeout when its next command was not accepted");

    if (checks > 0 && errs == 0) $display("SPI ARB2 TB PASS (%0d checks)", checks);
    else $display("SPI ARB2 TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "SPI ARB2 TB TIMEOUT");
  end
endmodule
