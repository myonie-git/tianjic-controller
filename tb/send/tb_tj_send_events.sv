// File        : tb_tj_send_events.sv
// Module      : tb_tj_send_events
// Description : Check SEND status and events across consecutive APB tasks.
`timescale 1ns/1ps
module tb_tj_send_events;
  import tj_ctrl_pkg::*;
  import tj_ctrl_csr_pkg::*;
  real p_hp = 5.0, m_hp = 1.2, m_phase = 0.0;
  logic pclk = 0, maxi_clk = 0, presetn = 0, maxi_rstn = 0;
  initial begin
    void'($value$plusargs("TJ_PCLK_HP=%f", p_hp));
    void'($value$plusargs("TJ_MAXI_HP=%f", m_hp));
    void'($value$plusargs("TJ_MAXI_PHASE=%f", m_phase));
    fork
      forever #(p_hp) pclk = ~pclk;
      begin #(m_phase); forever #(m_hp) maxi_clk = ~maxi_clk; end
    join
  end

  logic psel = 0, penable = 0, pwrite = 0;
  logic [15:0] paddr = 0;
  logic [31:0] pwdata = 0, prdata;
  logic pready, pslverr;
  tj_csr_i_t hwi;
  tj_csr_o_t hwo;
  logic sta_busy, sta_done_set, sta_err_set, irq_send_set, irq_axi_err_set;
  logic [31:0] sta_sent;
  logic req_valid, req_ready, rsp_valid, rsp_ready, rsp_last, rsp_err;
  logic [39:0] req_addr;
  logic [7:0] req_len;
  logic [127:0] rsp_data;
  logic [3:0] tx_tvalid, tx_tready;
  logic [3:0][95:0] tx_tdata;
  always_comb begin
    hwi = '0;
    hwi.send_sta_busy = sta_busy;
    hwi.glb_sta_send_busy = sta_busy;
    hwi.send_sta_done_set = sta_done_set;
    hwi.send_sta_err_set = sta_err_set;
    hwi.send_sent = sta_sent;
    hwi.irq_raw_set[9] = irq_send_set;
    hwi.irq_raw_set[28] = irq_axi_err_set;
  end
  tj_ctrl_csr u_csr (.*);
  tj_send_subsys #(.AW(40), .N_CH(3), .N_PORTS(4)) u_send (
    .pclk, .presetn, .db_go(hwo.send_db_go), .glb_srst(hwo.glb_ctrl_srst),
    .csr_src_lo(hwo.send_src_lo), .csr_src_hi(hwo.send_src_hi), .csr_cnt(hwo.send_cnt),
    .csr_lnk_en(hwo.lnk_en), .csr_remap0(hwo.lnk_remap0), .csr_remap1(hwo.lnk_remap1),
    .sta_busy, .sta_done_set, .sta_err_set, .irq_send_set, .irq_axi_err_set, .sta_sent,
    .maxi_clk, .maxi_rstn, .req_valid, .req_ready, .req_addr, .req_len,
    .rsp_valid, .rsp_ready, .rsp_data, .rsp_last, .rsp_err,
    .tx_tvalid, .tx_tready, .tx_tdata
  );

  int checks = 0, errs = 0;
  task automatic check(input bit ok, input string message);
    checks++;
    if (!ok) begin errs++; $display("FAIL: %s @ %0t", message, $time); end
  endtask
  task automatic apb_write(input logic [15:0] a, input logic [31:0] d);
    @(negedge pclk); psel = 1; penable = 0; pwrite = 1; paddr = a; pwdata = d;
    @(negedge pclk); penable = 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    check(!pslverr, $sformatf("APB write %h", a));
    @(negedge pclk); psel = 0; penable = 0;
  endtask
  task automatic apb_read(input logic [15:0] a, output logic [31:0] d);
    @(negedge pclk); psel = 1; penable = 0; pwrite = 0; paddr = a;
    @(negedge pclk); penable = 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    d = prdata;
    check(!pslverr, $sformatf("APB read %h", a));
    @(negedge pclk); psel = 0; penable = 0;
  endtask

  function automatic logic [127:0] memory_record(input logic [39:0] a);
    logic [7:0] channel;
    logic [95:0] packet;
    channel = (a[15:12] == 4'h3) ? 8'd13 : 8'((a >> 4) % 3);
    packet = {32'h13579BDF, a[31:0], 32'h2468ACE0};
    return {16'h0, 8'h0, channel, packet};
  endfunction

  typedef struct { logic [39:0] addr; int count; int due; } request_t;
  request_t requests[$];
  request_t active_request;
  int cycle = 0, remaining = 0, response_latency = 1;
  logic hold_response = 0;
  int n_req = 0, n_rsp = 0, n_tx = 0;
  logic [39:0] last_request_addr;
  logic [95:0] expected[4][$];
  assign req_ready = 1;
  assign tx_tready = 4'hF;
  always @(posedge maxi_clk or negedge maxi_rstn) begin
    if (!maxi_rstn) begin
      rsp_valid <= 0; rsp_last <= 0; rsp_err <= 0; rsp_data <= 0;
      cycle <= 0; remaining <= 0;
    end else begin
      cycle <= cycle + 1;
      if (req_valid && req_ready) begin
        request_t item;
        item.addr = req_addr; item.count = int'(req_len); item.due = cycle + response_latency;
        requests.push_back(item); n_req++; last_request_addr = req_addr;
      end
      if (rsp_valid && rsp_ready) begin
        n_rsp++;
        if (remaining > 1) begin
          remaining <= remaining - 1;
          active_request.addr = active_request.addr + 40'd16;
          rsp_data <= memory_record(active_request.addr);
          rsp_last <= (remaining == 2);
        end else begin
          remaining <= 0; rsp_valid <= 0; rsp_last <= 0; rsp_err <= 0;
        end
      end
      if (!rsp_valid && requests.size() != 0 && cycle >= requests[0].due && !hold_response) begin
        active_request = requests.pop_front();
        remaining <= active_request.count;
        rsp_valid <= 1;
        rsp_data <= memory_record(active_request.addr);
        rsp_last <= (active_request.count == 1);
        rsp_err <= (active_request.addr[15:12] == 4'h2);
      end
      for (int port_id = 0; port_id < 4; port_id++) begin
        if (tx_tvalid[port_id] && tx_tready[port_id]) begin
          logic [95:0] want;
          n_tx++;
          check(expected[port_id].size() > 0, $sformatf("Unexpected TX port %0d", port_id));
          if (expected[port_id].size() > 0) begin
            want = expected[port_id].pop_front();
            check(tx_tdata[port_id] === want, $sformatf("TX content port %0d", port_id));
          end
        end
      end
    end
  end
  int n_done = 0, n_err = 0, n_axi = 0;
  always @(posedge pclk) if (presetn) begin
    if (sta_done_set) n_done++;
    if (sta_err_set) n_err++;
    if (irq_axi_err_set) n_axi++;
  end

  task automatic run_job(input string name, input logic [39:0] base, input int count,
      input bit want_err, input bit want_axi, input bit extra_go = 0);
    int d0, e0, a0, req0, tx0;
    logic [31:0] status, raw, sent;
    logic [127:0] record;
    bit observed_busy, idle_before_done, first_read_idle, injected;
    for (int p = 0; p < 4; p++) begin
      check(expected[p].size() == 0, {name, ": prior queue drained"});
      expected[p].delete();
    end
    if (!want_err) for (int i = 0; i < count; i++) begin
      record = memory_record(base + 40'(i * 16));
      expected[record[103:96]].push_back(record[95:0]);
    end
    apb_write(16'h0C10, 32'h300);
    apb_write(16'h0100, 32'hFFFFFFFF);
    apb_write(16'h0C00, base[31:0]);
    apb_write(16'h0C04, {24'h0, base[39:32]});
    apb_write(16'h0C08, 32'(count));
    d0 = n_done; e0 = n_err; a0 = n_axi; req0 = n_req; tx0 = n_tx;
    observed_busy = 0; idle_before_done = 0; first_read_idle = 0; injected = 0;
    hold_response = extra_go;
    apb_write(16'h0C0C, 1);
    for (int poll = 0; poll < 2000; poll++) begin
      apb_read(16'h0C10, status);
      if (poll == 0) first_read_idle = (status[8:0] == 0);
      if (status[0]) observed_busy = 1;
      if (observed_busy && !status[0] && !status[8]) idle_before_done = 1;
      if (extra_go && observed_busy && !injected) begin
        apb_write(16'h0C0C, 1);
        repeat (20) @(negedge maxi_clk);
        hold_response = 0; injected = 1;
      end
      if (status[8]) break;
    end
    check(status[8], {name, ": DONE"});
    check(!status[0], {name, ": idle at DONE"});
    check(status[9] == want_err, $sformatf("%s: STA=%h expected ERR=%0b", name, status, want_err));
    apb_read(16'h0100, raw);
    check(raw[28] == want_axi, $sformatf("%s: RAW=%h expected AXI_ERR=%0b", name, raw, want_axi));
    check(raw[9], {name, ": completion IRQ"});
    for (int t = 0; t < 100; t++) begin
      apb_read(16'h0C14, sent);
      if (sent == (want_err ? 0 : count)) break;
    end
    check(sent == (want_err ? 0 : count), $sformatf("%s: SENT=%0d", name, sent));
    check(n_done == d0 + 1, {name, ": one completion event"});
    check(n_err == e0 + int'(want_err), $sformatf("%s: ERR events=%0d", name, n_err-e0));
    check(n_axi == a0 + int'(want_axi), $sformatf("%s: AXI events=%0d", name, n_axi-a0));
    check(n_req == req0 + 1, {name, ": one memory request"});
    check(last_request_addr == base, {name, ": source address"});
    check(n_tx == tx0 + (want_err ? 0 : count), {name, ": packet count"});
    for (int p = 0; p < 4; p++) check(expected[p].size() == 0, {name, ": expected data consumed"});
    $display("JOB %s STA=%h RAW=%h SENT=%0d events=%0d/%0d/%0d first_read_idle=%0b idle_before_done=%0b",
      name, status, raw, sent, n_done-d0, n_err-e0, n_axi-a0, first_read_idle, idle_before_done);
    repeat (50) @(negedge pclk);
  endtask

  int canceled_starts = 0, drained_starts = 0;
  bit check_abort_spacing = 0;
  realtime last_go_time;
  always @(posedge pclk) if (presetn) begin
    if (hwo.send_db_go) last_go_time = $realtime;
    if (hwo.glb_ctrl_srst && check_abort_spacing)
      check(($realtime - last_go_time) >= (6.0*m_hp - 0.001), "GO/SRST spacing");
  end

  // Withhold read responses until abort arrives; no packet may be transmitted.
  task automatic abort_start(input string name);
    int d0, e0, a0, req0, tx0;
    logic [31:0] status, raw;
    real delay_ns;
    for (int p = 0; p < 4; p++) check(expected[p].size() == 0, "prior task drained");
    apb_write(16'h0C10, 32'h300);
    apb_write(16'h0100, 32'hFFFFFFFF);
    apb_write(16'h0C00, 32'h1000);
    apb_write(16'h0C04, 0);
    apb_write(16'h0C08, 3);
    d0 = n_done; e0 = n_err; a0 = n_axi; req0 = n_req; tx0 = n_tx;
    hold_response = 1;
    check_abort_spacing = 1;
    apb_write(16'h0C0C, 1);
    delay_ns = 6.0*m_hp - 6.0*p_hp;
    if (delay_ns < 0.0) delay_ns = 0.0;
    #(delay_ns + 0.001);
    apb_write(16'h000C, 1);
    repeat (12) @(negedge maxi_clk);
    repeat (12) @(negedge pclk);
    check_abort_spacing = 0;
    hold_response = 0;
    for (int poll = 0; poll < 2000; poll++) begin
      apb_read(16'h0C10, status);
      if (!status[0]) break;
    end
    repeat (12) @(negedge pclk);
    apb_read(16'h0C10, status);
    apb_read(16'h0100, raw);
    check(!status[0] && !status[8] && !status[9], {name, ": idle without DONE/ERR"});
    check(!raw[9] && !raw[28], {name, ": no stale IRQ"});
    check(n_done == d0 && n_err == e0 && n_axi == a0, {name, ": no stale event pulses"});
    check(n_tx == tx0, {name, ": no packet transmitted"});
    check(n_req >= req0 && n_req <= req0 + 1, {name, ": at most one committed read"});
    if (n_req == req0) canceled_starts++;
    else drained_starts++;
  endtask

  initial begin
    repeat (6) @(negedge pclk);
    presetn = 1; maxi_rstn = 1;
    repeat (10) @(negedge pclk);
    $display("CLOCK pclk=%0f MHz maxi=%0f MHz phase=%0f ns", 500.0/p_hp, 500.0/m_hp, m_phase);
    apb_write(16'h2000, 7);
    apb_write(16'h2004, 32'h76543210);
    apb_write(16'h2008, 32'h0000BA98);
    run_job("normal_one", 40'h1000, 1, 0, 0);
    run_job("normal_nine", 40'h1040, 9, 0, 0);
    for (int j = 0; j < 3; j++) run_job($sformatf("fast_axi_error_%0d",j), 40'h2000, 1, 1, 1);
    run_job("recovery", 40'h1080, 3, 0, 0);
    for (int j = 0; j < 3; j++) run_job($sformatf("illegal_record_%0d",j), 40'h3000, 1, 1, 0);
    response_latency = 20;
    for (int j = 0; j < 3; j++) run_job($sformatf("slow_axi_error_%0d",j), 40'h2000, 1, 1, 1);
    run_job("busy_GO_ignored", 40'h10C0, 3, 0, 0, 1);
    // Alternate a completed error with a short GO-to-abort interval.
    for (int i = 0; i < 16; i++) begin
      run_job($sformatf("before_start_abort_%0d", i), 40'h2000, 1, 1, 1);
      abort_start($sformatf("start_abort_%0d", i));
    end
    run_job("restart_after_start_abort", 40'h1040, 9, 0, 0);
    $display("STARTUP_ABORT canceled=%0d drained=%0d", canceled_starts, drained_starts);
    if (errs == 0 && checks > 0) $display("SEND EVENTS TB PASS (%0d checks)", checks);
    else $display("SEND EVENTS TB FAIL (%0d/%0d checks)", errs, checks);
    $finish;
  end
  initial begin #5ms; $fatal(1, "SEND EVENTS TIMEOUT"); end
endmodule
