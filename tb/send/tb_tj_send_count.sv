// File        : tb_tj_send_count.sv
// Module      : tb_tj_send_count
// Description : Check SEND count coherence and convergence through public ports.
`timescale 1ns/1ps

module tb_tj_send_count;
  function automatic real half_period(input string key, input real fallback);
    real value;
    if ($value$plusargs({key, "=%f"}, value)) return value;
    return fallback;
  endfunction

  real pclk_hp = half_period("TJ_PCLK_HP", 5.0);
  real maxi_hp = half_period("TJ_MAXI_HP", 1.2);
  logic pclk = 0, maxi_clk = 0, presetn = 0, maxi_rstn = 0;
  always #(pclk_hp) pclk = ~pclk;
  always #(maxi_hp) maxi_clk = ~maxi_clk;

  logic go = 0;
  logic [31:0] cfg_count = 264;
  logic busy, done_set, err_set, irq_set, axi_set;
  logic [31:0] sent;
  logic req_valid, req_ready, rsp_ready;
  logic [39:0] req_addr;
  logic [7:0] req_len;
  logic rsp_valid = 0, rsp_last = 0;
  logic [127:0] rsp_data = 0;
  logic [3:0] tx_valid, tx_ready = 0;
  logic [3:0][95:0] tx_data;
  int accepted = 0, limit_count = 0, requested = 0, returned = 0;
  int response_left = 0, checks = 0, errs = 0, done_count = 0;
  int monitor_lo = 0, monitor_hi = 0;
  bit observe_transition = 0;

  tj_send_subsys #(.N_CH(3), .N_PORTS(4), .AW(40)) u_send (
    .pclk, .presetn, .db_go(go), .glb_srst(1'b0),
    .csr_src_lo(32'h1000), .csr_src_hi(16'd0), .csr_cnt(cfg_count),
    .csr_lnk_en(12'h007), .csr_remap0(32'h76543210), .csr_remap1(16'hBA98),
    .sta_busy(busy), .sta_done_set(done_set), .sta_err_set(err_set),
    .irq_send_set(irq_set), .irq_axi_err_set(axi_set), .sta_sent(sent),
    .maxi_clk, .maxi_rstn, .req_valid, .req_ready, .req_addr, .req_len,
    .rsp_valid, .rsp_ready, .rsp_data, .rsp_last, .rsp_err(1'b0),
    .tx_tvalid(tx_valid), .tx_tready(tx_ready), .tx_tdata(tx_data)
  );

  task automatic check(input bit ok, input string message);
    checks++;
    if (!ok) begin
      errs++;
      $display("FAIL: %s @ %0t", message, $time);
    end
  endtask

  function automatic logic [95:0] packet(input int index);
    return {32'hA516_0055, 32'(index), 32'h0000_0002};
  endfunction

  assign req_ready = !rsp_valid;
  always @(posedge maxi_clk) if (maxi_rstn) begin
    if (req_valid && req_ready) begin
      check(req_len != 0 && requested + req_len <= cfg_count,
            "Read request length");
      check(req_addr == 40'h1000 + 16 * requested, "Sequential read address");
      response_left <= req_len;
      requested <= requested + req_len;
      rsp_valid <= 1;
      rsp_last <= (req_len == 1);
      rsp_data <= {32'd0, packet(returned)};
    end else if (rsp_valid && rsp_ready) begin
      response_left <= response_left - 1;
      returned <= returned + 1;
      rsp_data <= {32'd0, packet(returned + 1)};
      rsp_last <= (response_left == 2);
      if (response_left == 1) rsp_valid <= 0;
    end
    if (tx_valid[0] && tx_ready[0]) begin
      check(tx_data[0] == packet(accepted), "Packet content and order");
      accepted++;
    end
    if (|tx_valid[3:1]) check(0, "Unexpected output channel");
  end

  always @(negedge maxi_clk)
    tx_ready = (maxi_rstn && accepted < limit_count) ? 4'h1 : 4'h0;

  always @(posedge pclk) if (presetn) begin
    if (done_set) done_count++;
    if (err_set || axi_set) check(0, "Unexpected error event");
  end

  always @(negedge pclk) if (observe_transition)
    check(sent == monitor_lo || sent == monitor_hi,
          $sformatf("Coherent SENT: expected %0d or %0d, got %0d",
                    monitor_lo, monitor_hi, sent));

  task automatic settle;
    repeat (12) @(negedge maxi_clk);
    repeat (12) @(negedge pclk);
    repeat (12) @(negedge maxi_clk);
    repeat (12) @(negedge pclk);
  endtask

  task automatic hold_count(input int target);
    limit_count = target;
    wait (accepted == target);
    settle();
    check(sent == target, $sformatf("Stable SENT converges to %0d", target));
  endtask

  task automatic check_carry(input int target);
    hold_count(target - 1);
    monitor_lo = target - 1;
    monitor_hi = target;
    observe_transition = 1;
    hold_count(target);
    observe_transition = 0;
    $display("CARRY %0d -> %0d checked", target - 1, target);
  endtask

  task automatic launch;
    @(negedge pclk); go = 1;
    @(negedge pclk); go = 0;
  endtask

  initial begin
    $display("CLOCK half-periods: pclk=%0.3f ns maxi=%0.3f ns", pclk_hp, maxi_hp);
    repeat (6) @(negedge pclk);
    presetn = 1;
    maxi_rstn = 1;
    settle();
    check(sent == 0 && !busy, "Reset count and status");

    // P1: Isolate multi-bit carries while output traffic is paused on either side.
    launch();
    check_carry(32);
    check_carry(64);
    check_carry(128);
    check_carry(256);

    // P2: Drain the job and allow the independent count snapshot to converge.
    limit_count = 264;
    wait (done_count != 0);
    settle();
    check(sent == 264 && accepted == 264, "Final count after snapshot convergence");
    check(done_count == 1 && !busy, "One completion and idle");
    check(requested == 264 && returned == 264, "All records fetched");

    // P3: A new job must replace the previous job's count.
    @(negedge maxi_clk);
    accepted = 0;
    limit_count = 0;
    requested = 0;
    returned = 0;
    cfg_count = 8;
    settle();
    launch();
    hold_count(7);
    limit_count = 8;
    wait (done_count == 2);
    settle();
    check(sent == 8 && accepted == 8, "Second job count");
    check(!busy && requested == 8 && returned == 8, "Second job complete");

    if (checks > 0 && errs == 0)
      $display("SEND COUNT TB PASS (%0d checks)", checks);
    else
      $display("SEND COUNT TB FAIL (%0d/%0d checks)", errs, checks);
    $finish;
  end

  initial begin
    #2ms;
    $fatal(1, "SEND COUNT TIMEOUT");
  end
endmodule
