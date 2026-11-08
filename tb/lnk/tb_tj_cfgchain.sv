// File        : tb_tj_cfgchain.sv
// Module      : tb_tj_cfgchain
// Description : Check configuration-chain commands, CSR status and write hold timing.
//               Uses native chain receivers and a public APB register model.

module tb_tj_cfgchain;
  timeunit 1ns;
  timeprecision 1ps;
  `include "tj_case_select.svh"
  import tj_ctrl_csr_pkg::*;
  real hp = 5.0;
  initial if (!$value$plusargs("TJ_PCLK_HP=%f", hp)) hp = 5.0;
  logic clk = 0, rst_n = 0;
  always #(hp) clk = ~clk;
  logic psel = 0, penable = 0, pwrite = 0;
  logic [15:0] paddr = 0;
  logic [31:0] pwdata = 0, prdata;
  logic pready, pslverr;
  tj_csr_i_t hwi;
  tj_csr_o_t hwo;
  logic [31:0] rdata;
  logic busy, dvld;
  logic raw_mode = 0, raw_go = 0;
  logic [1:0] raw_kind = 0, raw_inst = 0;
  logic [31:0] raw_wdata = 0;
  logic [2:0][32:0] din;
  logic [2:0] din_vld;
  logic [2:0][31:0] dout;
  logic [2:0] dout_vld;
  logic [2:0][1:0] ids;
  logic [1:0] target_sel, target_enable, target_write;
  logic [1:0][24:0] target_addr;
  logic [1:0][31:0] target_wdata, target_rdata;
  logic target_hold = 0;
  logic [31:0] memory [2][4];
  int writes [2];
  int command_count = 0;
  int dvld_count = 0;
  always @(posedge clk) if (rst_n && dvld) dvld_count++;
  int checks = 0, errs = 0;

  tj_ctrl_csr csr (
    .pclk(clk), .presetn(rst_n), .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .hwi(hwi), .hwo(hwo)
  );
  always_comb begin
    hwi = '0;
    hwi.cc_rdata = rdata;
    hwi.cc_sta_busy = busy;
    hwi.cc_sta_dvld_set = dvld;
    hwi.glb_sta_cc_busy = busy;
  end
  tj_cfgchain_master master (
    .clk(clk), .rst_n(rst_n),
    .db_go(raw_mode ? raw_go : hwo.cc_db_go),
    .kind(raw_mode ? raw_kind : hwo.cc_cmd_kind),
    .inst(raw_mode ? raw_inst : hwo.cc_cmd_inst),
    .wdata(raw_mode ? raw_wdata : hwo.cc_wdata),
    .rdata_o(rdata), .busy_o(busy), .dvld_set_o(dvld),
    .din(din[0]), .din_vld(din_vld[0]), .dout(dout[0]), .dout_vld(dout_vld[0])
  );
  assign ids[0] = 0;
  assign dout[2] = 0;
  assign dout_vld[2] = 0;
  for (genvar g = 0; g < 2; g++) begin : targets
    lvds_core_cfg_wrap target (
      .clk(clk), .rstn(rst_n), .CORE_ID(ids[g]), .CORE_ID_NEXT(ids[g+1]),
      .din_pre(din[g]), .din_pre_vld(din_vld[g]), .din_next(din[g+1]), .din_next_vld(din_vld[g+1]),
      .dout_pre(dout[g]), .dout_pre_vld(dout_vld[g]), .dout_next(dout[g+1]), .dout_next_vld(dout_vld[g+1]),
      .apb_psel(target_sel[g]), .apb_penable(target_enable[g]), .apb_pwrite(target_write[g]),
      .apb_paddr(target_addr[g]), .apb_pwdata(target_wdata[g]),
      .apb_pready(!target_hold), .apb_prdata(target_rdata[g])
    );
    assign target_rdata[g] = memory[g][target_addr[g][3:2]];
    always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        writes[g] = 0;
        for (int i = 0; i < 4; i++) memory[g][i] = 0;
      end else if (target_sel[g] && target_enable[g] && !target_hold && target_write[g]) begin
        memory[g][target_addr[g][3:2]] = target_wdata[g];
        writes[g]++;
      end
    end
  end
  always @(posedge clk) if (rst_n && din_vld[0]) command_count++;

  task automatic chk(input logic condition, input string message);
    checks++;
    if (condition !== 1'b1) begin
      errs++;
      $display("FAIL: %s @%0t", message, $time);
    end
  endtask
  task automatic xfer(input bit wr, input logic [15:0] address, input logic [31:0] data,
                       output logic [31:0] value);
    @(negedge clk);
    psel = 1;
    penable = 0;
    pwrite = wr;
    paddr = address;
    pwdata = data;
    @(negedge clk);
    penable = 1;
    @(posedge clk);
    chk(pready && !pslverr, "APB access");
    value = prdata;
  endtask
  task automatic wr(input logic [15:0] address, input logic [31:0] data);
    logic [31:0] unused;
    xfer(1, address, data, unused);
  endtask
  task automatic idle;
    @(negedge clk);
    psel = 0;
    penable = 0;
  endtask
  task automatic issue(input logic [1:0] op, input logic [1:0] target, input logic [31:0] value);
    wr(16'h3800, {26'd0, target, 2'd0, op});
    wr(16'h3804, value);
    wr(16'h380c, 1);
  endtask
  task automatic poll(input bit read_op, input bit expect_timeout, output logic [31:0] status);
    bit ended;
    ended = 0;
    for (int i = 0; i < 2300; i++) begin
      xfer(0, 16'h3810, 0, status);
      if (read_op && !expect_timeout)
        chk(status[0] || status[8], "Read BUSY/DVLD must not both be zero");
      if (!status[0]) begin
        ended = 1;
        break;
      end
    end
    chk(ended, "Operation finishes within polling budget");
    if (read_op) chk(status[8] == !expect_timeout, "Expected new DVLD result");
  endtask
  task automatic cc_write(input logic [1:0] target, input logic [31:0] address, value);
    logic [31:0] status;
    issue(0, target, address);
    poll(0, 0, status);
    issue(1, target, value);
    poll(0, 0, status);
  endtask
  task automatic cc_read(input logic [1:0] target, op, input int phase,
                         input logic [31:0] address, expected);
    logic [31:0] status, value;
    wr(16'h3810, 32'h100);
    issue(op, target, address);
    if (phase) idle();
    poll(1, 0, status);
    xfer(0, 16'h3808, 0, value);
    chk(value == expected, "Readback value");
  endtask
  task automatic reset_all;
    idle();
    rst_n = 0;
    raw_go = 0;
    target_hold = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);
  endtask
  task automatic raw_beat(input logic [1:0] target, op, input logic [31:0] value);
    @(negedge clk);
    while (busy) @(negedge clk);
    chk(!busy, "Direct command starts only when idle");
    raw_kind = op;
    raw_wdata = value;
    raw_inst = target;
    raw_go = 1;
    @(negedge clk);
    raw_go = 0;
  endtask

  initial begin
    logic [31:0] status, value;
    int start_count;
    tj_cases_init("P1,P2,P3,P4");
    if (tj_case_filter_active && !tj_case_wanted("P1")) reset_all();
    // P1: CSR readback, instance selection, KIND 2/3 and both polling phases.
    if (tj_run_case("P1")) begin
      reset_all();
      cc_write(0, 4, 32'ha1234567);
      cc_write(1, 4, 32'hb7654321);
      for (int phase = 0; phase < 2; phase++) begin
        cc_read(0, 2, phase, 4, 32'ha1234567);
        cc_read(1, 2, phase, 4, 32'hb7654321);
        cc_read(0, 3, phase, 4, 32'ha1234567);
      end
      wr(16'h3810, 32'h100);
    end

    // P2: A missing target times out; subsequent accesses still complete.
    if (tj_run_case("P2")) begin
      issue(2, 3, 4);
      poll(1, 1, status);
      cc_write(0, 8, 32'hc001abcd);
      cc_read(0, 2, 0, 8, 32'hc001abcd);

      wr(16'h3810, 32'h100);
    end

    // P3: GO while busy must not replace or queue a command.
    if (tj_run_case("P3")) begin
      if (tj_case_filter_active) begin
        // Finish the seed write before holding the target response.
        cc_write(0, 4, 32'ha1234567);
        cc_read(0, 2, 0, 4, 32'ha1234567);
        wr(16'h3810, 32'h100);
      end
      idle();
      target_hold = 1;
      start_count = command_count;
      issue(2, 0, 4);
      xfer(0, 16'h3810, 0, status);
      chk(status[0], "Target hold keeps reader busy");
      issue(1, 0, 32'hbadbad00);
      idle();
      target_hold = 0;
      poll(1, 0, status);
      xfer(0, 16'h3808, 0, value);
      chk(value == 32'ha1234567, "Busy GO leaves the current read unchanged");
      chk(command_count == start_count+1, "Busy GO was not sent to the chain");
      idle();
    end

    // P4: Submit on the first idle cycle and verify both targets through readback.
    if (tj_run_case("P4")) begin
      raw_mode = 1;
      for (int target = 0; target < 2; target++) begin
        int start_dvld;
        reset_all();
        start_dvld = dvld_count;
        raw_beat(2'(target), 0, 4);
        raw_beat(2'(target), 1, 32'h12345678);
        raw_beat(2'(target), 0, 8);
        raw_beat(2'(target), 1, 32'h89abcdef);
        repeat (16) @(negedge clk);
        chk(writes[target] == 2, "Idle-paced writes must both reach the target");
        chk(writes[1-target] == 0, "Other target remains unchanged");
        chk(memory[target][1] == 32'h12345678, "First idle-paced write value");
        chk(memory[target][2] == 32'h89abcdef, "Second idle-paced write value");
        chk(dvld_count == start_dvld, "Writes do not report read data valid");
        raw_beat(2'(target), 2, 4);
        while (busy) @(negedge clk);
        chk(rdata == 32'h12345678, "Readback after idle-paced writes");
        chk(dvld_count == start_dvld+1, "One read result event");
      end
    end

    if (checks > 0 && errs == 0) $display("CFGCHAIN TB PASS (%0d checks)", checks);
    else $display("CFGCHAIN TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end
  initial begin
    #500000;
    $fatal(1, "CFGCHAIN TB TIMEOUT");
  end
endmodule
