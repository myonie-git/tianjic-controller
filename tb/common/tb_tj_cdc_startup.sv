// File        : tb_tj_cdc_startup.sv
// Module      : tb_tj_cdc_startup
// Description : Check startup pulses, event coalescing and common reset.
`timescale 1ns/1ps
module tb_tj_cdc_startup;
  real s_hp = 5.0, d_hp = 1.2;
  logic sclk = 0, dclk = 0, run_sclk = 0, run_dclk = 0;
  logic srst_n = 0, drst_n = 0, pulse_i = 0;
  logic [1:0] evt_i = 0;
  wire pulse_o;
  wire [1:0] set_o;
  // DIVW=10 satisfies the documented spacing for all tested ratios.
  tj_pulse_sync u_pulse (.*);
  tj_evt_sync #(.W(2), .DIVW(10)) u_evt (.*);
  int checks = 0, errs = 0, pulses = 0, events0 = 0, events1 = 0;
  initial begin
    void'($value$plusargs("TJ_PCLK_HP=%f", s_hp));
    void'($value$plusargs("TJ_MAXI_HP=%f", d_hp));
    fork
      forever begin #(s_hp); if (run_sclk) sclk = ~sclk; else sclk = 0; end
      forever begin #(d_hp); if (run_dclk) dclk = ~dclk; else dclk = 0; end
    join
  end
  always @(posedge dclk) if (drst_n) begin
    if (pulse_o) pulses++;
    if (set_o[0]) events0++;
    if (set_o[1]) events1++;
  end
  task automatic chk(input bit ok, input string msg);
    checks++;
    if (!ok) begin errs++; $display("FAIL: %s", msg); end
  endtask
  task automatic reset_pair();
    run_sclk = 0; run_dclk = 0;
    srst_n = 0; drst_n = 0; pulse_i = 0; evt_i = 0;
    #(4*(s_hp+d_hp));
    pulses = 0; events0 = 0; events1 = 0;
  endtask
  initial begin
    #(1ps);
    // Sweep first-event timing with both resets released together. The source
    // starts first; destination clock phase is then varied before its first edge.
    for (int phase = 0; phase < 8; phase++) begin
      reset_pair();
      srst_n = 1; drst_n = 1;
      pulse_i = 1; evt_i = 2'b01; run_sclk = 1;
      @(negedge sclk); pulse_i = 0; evt_i = 0;
      #(d_hp * real'(phase) / 8.0); run_dclk = 1;
      repeat (14) @(negedge dclk);
      chk(pulses == 1, $sformatf("startup pulse phase=%0d count=%0d", phase, pulses));
      chk(events0 == 1 && events1 == 0,
          $sformatf("startup event phase=%0d count=%0d/%0d", phase, events0, events1));
      repeat (16) @(negedge dclk);
      chk(pulses == 1 && events0 == 1, "no duplicate startup events");
    end
    reset_pair();
    srst_n = 1; drst_n = 1; run_sclk = 1; run_dclk = 1;
    repeat (20) @(negedge dclk);
    chk(pulses == 0 && events0 == 0 && events1 == 0, "no event after reset");
    for (int i = 0; i < 5; i++) begin
      @(negedge sclk); pulse_i = 1;
      @(negedge sclk); pulse_i = 0;
      repeat (12) @(negedge dclk);
      chk(pulses == i+1, "settled pulse transferred once");
    end
    @(negedge sclk); evt_i = 2'b10;
    repeat (4) @(negedge sclk);
    evt_i = 0;
    repeat (1030) @(negedge sclk);
    repeat (20) @(negedge dclk);
    chk(events0 == 0 && events1 == 1, "same-window events coalesced per bit");
    if (errs == 0 && checks > 0) $display("CDC STARTUP TB PASS (%0d checks)", checks);
    else $display("CDC STARTUP TB FAIL (%0d/%0d checks)", errs, checks);
    $finish;
  end
  initial begin #10ms; $fatal(1, "CDC STARTUP TB TIMEOUT"); end
endmodule
