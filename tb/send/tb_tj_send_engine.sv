// File        : tb_tj_send_engine.sv
// Module      : tb_tj_send_engine
// Description : Check packet replacement, backpressure, abort and completion.
`timescale 1ns/1ps
module tb_tj_send_engine;
  import tj_ctrl_pkg::*;
  logic clk = 0, rst_n = 0, go = 0, abort = 0, src_done = 0;
  logic [11:0] cfg_lnk_en = 12'h007;
  logic [31:0] cfg_remap0 = 32'h76543210;
  logic [15:0] cfg_remap1 = 16'hBA98;
  logic busy, done_pulse, err_pulse, irq_pulse;
  logic [31:0] sent;
  logic rec_valid = 0, rec_ready;
  tj_rec_t rec;
  logic [3:0] tx_tvalid, tx_tready = 0;
  logic [3:0][95:0] tx_tdata;
  tj_send_engine #(.N_CH(3), .N_PORTS(4)) dut (.*);
  always #5 clk = ~clk;
  logic [95:0] expected[4][$];
  bit expected_irq[4][$];
  logic [3:0] held;
  logic [3:0][95:0] held_data;
  int checks = 0, errs = 0, accepted = 0, done_count = 0;
  int cyc = 0, first_tx = -1, last_tx = -1;
  task automatic chk(input bit ok, input string msg);
    checks++;
    if (!ok) begin errs++; $display("FAIL: %s @%0t", msg, $time); end
  endtask
  function automatic tj_rec_t item(input int i, input int ch, input bit mark);
    return {16'(i), (mark ? 8'h04 : 8'h00), 8'(ch), 32'h13579BDF, 32'(i), 32'h2468ACE0};
  endfunction
  always @(posedge clk) begin
    if (!rst_n) begin
      held = 0; accepted = 0; done_count = 0; cyc = 0;
      first_tx = -1; last_tx = -1;
      for (int p=0; p<4; p++) begin expected[p].delete(); expected_irq[p].delete(); end
    end else begin
      bit want_irq;
      logic [95:0] packet;
      bit mark;
      want_irq = 0; cyc++;
      for (int p=0; p<4; p++) begin
        if (held[p]) chk(tx_tvalid[p] && tx_tdata[p] === held_data[p], "VALID/data retained under backpressure");
        if (tx_tvalid[p] && tx_tready[p]) begin
          chk(expected[p].size() > 0, "output has matching input record");
          if (expected[p].size() > 0) begin
            packet = expected[p].pop_front(); mark = expected_irq[p].pop_front();
            chk(tx_tdata[p] === packet, "output data/order");
            want_irq |= mark;
          end
          accepted++;
          if (first_tx < 0) first_tx = cyc;
          last_tx = cyc;
        end
      end
      if (rec_valid && rec_ready && !abort) begin
        expected[rec.ch].push_back(rec.pkt);
        expected_irq[rec.ch].push_back(rec.flags[2]);
      end
      held = tx_tvalid & ~tx_tready; held_data = tx_tdata;
      #1ps;
      if (done_pulse) done_count++;
      chk(sent == accepted, "SENT counts accepted output packets");
      chk(irq_pulse === want_irq, "IRQ belongs to the packet accepted this cycle");
      chk(!err_pulse, "valid test records produce no record error");
    end
  end
  task automatic reset_job();
    @(negedge clk);
    rst_n = 0; go = 0; abort = 0; rec_valid = 0; src_done = 0; tx_tready = 0;
    repeat (3) @(negedge clk);
    rst_n = 1; go = 1;
    @(negedge clk); go = 0;
  endtask
  task automatic push(input int i, input int ch, input bit mark);
    @(negedge clk); rec_valid = 1; rec = item(i,ch,mark);
    @(posedge clk); while (!rec_ready) @(posedge clk);
    @(negedge clk); rec_valid = 0;
  endtask
  task automatic finish_job(input int n);
    for (int i=0; i<100; i++) begin @(negedge clk); if (!busy) break; end
    chk(!busy && done_count == 1, "normal job completes exactly once");
    chk(accepted == n, "all records accepted");
  endtask
  initial begin
    rec = '0;
    reset_job();
    tx_tready = 4'hF;
    // A continuous producer with alternating IRQ markers tests old/new packet replacement.
    @(negedge clk); rec_valid = 1;
    for (int i=0; i<64; i++) begin
      rec = item(i,0,(i%3)==0);
      @(posedge clk); while (!rec_ready) @(posedge clk);
      @(negedge clk);
    end
    rec_valid = 0; src_done = 1;
    finish_job(64);
    chk(last_tx-first_tx == 63, "one packet per cycle on the same port");

    reset_job();
    push(100,0,0); push(101,1,0); push(102,2,1);
    repeat (5) @(negedge clk);
    chk(tx_tvalid == 4'h7, "three output packets pending before abort");
    // Abort coincides with accepting port 0. Ports 1 and 2 must remain pending.
    abort = 1; tx_tready = 4'h1;
    @(negedge clk); abort = 0; tx_tready = 0;
    repeat (8) @(negedge clk);
    chk(busy && tx_tvalid == 4'h6, "abort retains remaining packets and BUSY");
    chk(done_count == 0, "abort does not emit completion");
    tx_tready = 4'h2;
    repeat (3) @(negedge clk);
    chk(accepted == 2 && busy, "partial drain remains busy");
    tx_tready = 4'h4;
    repeat (5) @(negedge clk);
    chk(accepted == 3 && !busy && done_count == 0, "abort drains every pending packet without DONE");

    reset_job();
    push(200,0,1);
    // A replacement record is offered on the same cycle as abort and old-packet acceptance.
    rec = item(201,0,0); rec_valid = 1; tx_tready = 4'h1; abort = 1;
    @(negedge clk); abort = 0; rec_valid = 0;
    repeat (8) @(negedge clk);
    chk(accepted == 1 && !busy && done_count == 0, "abort suppresses same-cycle replacement");

    reset_job();
    push(300,0,1); push(301,1,1); push(302,2,0);
    src_done = 1;
    repeat (4) @(negedge clk);
    chk(busy && done_count == 0, "completion waits for every output");
    tx_tready = 4'h7;
    finish_job(3);
    chk(first_tx == last_tx, "three ports accepted simultaneously");
    if (errs == 0 && checks > 0) $display("SEND ENGINE TB PASS (%0d checks)", checks);
    else $display("SEND ENGINE TB FAIL (%0d/%0d checks)", errs, checks);
    $finish;
  end
  initial begin #2ms; $fatal(1, "SEND ENGINE TB TIMEOUT"); end
endmodule
