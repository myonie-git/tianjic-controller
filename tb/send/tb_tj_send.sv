// File        : tb_tj_send.sv
// Module      : tb_tj_send
// Description : Test SEND through APB, an AXI read model and LVDS sinks.
`timescale 1ns/1ps
module tb_tj_send;
  // Expected TX record format, independent of the DUT package.
  localparam logic [7:0] REC_LAST  = 8'h01;
  localparam logic [7:0] REC_FENCE = 8'h02;
  localparam logic [7:0] REC_IRQ   = 8'h04;
  localparam int unsigned TEST_N_CH = 3;

  localparam real DEFAULT_PCLK_HP = 5.0;
  localparam real DEFAULT_MAXI_HP = 1.2;

  function automatic real half_period(input string key, input real fallback);
    real value;
    if (!$value$plusargs({key, "=%f"}, value)) value = fallback;
    if (value < 0.001) $fatal(1, "%s must be at least 0.001 ns", key);
    return value;
  endfunction

  // Clock half-periods in ns, selected with +TJ_PCLK_HP and +TJ_MAXI_HP.
  real pclk_hp = half_period("TJ_PCLK_HP", DEFAULT_PCLK_HP);
  real maxi_hp = half_period("TJ_MAXI_HP", DEFAULT_MAXI_HP);
  logic pclk = 0, presetn = 0, maxi_clk = 0, maxi_rstn = 0;
  always #(pclk_hp) pclk = ~pclk;
  always #(maxi_hp) maxi_clk = ~maxi_clk;

  // Preserve each timeout's clock-cycle margin at the selected clock ratio.
  function automatic real clock_scale();
    real p_scale, m_scale;
    p_scale = pclk_hp / DEFAULT_PCLK_HP;
    m_scale = maxi_hp / DEFAULT_MAXI_HP;
    return (p_scale > m_scale) ? p_scale : m_scale;
  endfunction

  function automatic int unsigned apb_poll_limit(input int unsigned default_limit);
    return int'($ceil(default_limit * clock_scale() * DEFAULT_PCLK_HP / pclk_hp));
  endfunction

  int unsigned errs = 0, checks = 0;
  task automatic chk(input bit c, input string m);
    checks++;
    if (!c) begin errs++; $display("FAIL: %s @%0t", m, $time); end
  endtask

  // CSR offsets.
  localparam [15:0] A_GLB_CTRL = 16'h000C;
  localparam [15:0] A_GLB_STA  = 16'h0010;
  localparam [15:0] A_IRQ_RAW  = 16'h0100;
  localparam [15:0] A_SRC_LO   = 16'h0C00;
  localparam [15:0] A_SRC_HI   = 16'h0C04;
  localparam [15:0] A_CNT      = 16'h0C08;
  localparam [15:0] A_DB       = 16'h0C0C;
  localparam [15:0] A_STA      = 16'h0C10;
  localparam [15:0] A_SENT     = 16'h0C14;
  localparam [15:0] A_LNK_EN   = 16'h2000;
  localparam [15:0] A_REMAP0   = 16'h2004;
  localparam [15:0] A_REMAP1   = 16'h2008;

  // DUT: three channel groups on one four-port LVDS instance.
  localparam int unsigned NP = 4;
  logic        psel, penable, pwrite, pready, pslverr;
  logic [15:0] paddr;
  logic [31:0] pwdata, prdata;
  logic        arvalid, arready, rvalid, rready, rlast;
  logic [3:0]  arid, rid;
  logic [47:0] araddr;
  logic [7:0]  arlen;
  logic [2:0]  arsize;
  logic [1:0]  arburst, rresp;
  logic [127:0] rdata;
  logic [NP-1:0]        lv_tx_tvalid, lv_tx_tready;
  logic [NP-1:0][95:0]  lv_tx_tdata;
  logic [3:0]  irq;

  tj_send_verification_top u_dut (
    .pclk, .presetn, .maxi_clk, .maxi_rstn,
    .psel, .penable, .pwrite, .paddr, .pwdata, .pready, .pslverr, .prdata,
    .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
    .rvalid, .rready, .rdata, .rresp, .rlast, .rid,
    .irq, .lv_tx_tvalid, .lv_tx_tready, .lv_tx_tdata
  );

  // Check AXI request stability, burst limits and response draining.
  bit ar_was_stalled = 0;
  logic [47:0] held_araddr;
  logic [7:0] held_arlen;
  int outstanding = 0, max_outstanding = 0, total_ar = 0, total_r = 0;
  int ar0, r0;
  bit watch_boundary = 0;
  int boundary_requests = 0;
  logic [47:0] boundary_addresses[4] = '{48'h10000FC0,48'h10001000,48'h10001400,48'h10001800};
  logic [7:0] boundary_lengths[4] = '{8'd3,8'd63,8'd63,8'd8};
  always @(posedge maxi_clk) if (maxi_rstn) begin
    if (ar_was_stalled)
      chk(arvalid && araddr == held_araddr && arlen == held_arlen, "AR stable while stalled");
    if (arvalid) begin
      chk(arsize == 4 && arburst == 1 && arid == 0, "128-bit INCR fixed-ID request");
      chk(int'(araddr[11:0]) + (int'(arlen)+1)*16 <= 4096, "burst stays within 4 KiB");
      chk(arlen < 64, "burst is at most 64 records");
    end
    if (arvalid && arready) begin
      outstanding++; total_ar++;
      if (outstanding > max_outstanding) max_outstanding = outstanding;
      if (watch_boundary) begin
        chk(boundary_requests < 4, "four expected boundary requests");
        if (boundary_requests < 4)
          chk(araddr == boundary_addresses[boundary_requests] && arlen == boundary_lengths[boundary_requests],
              "4 KiB split addresses and lengths");
        boundary_requests++;
      end
    end
    if (rvalid && rready) total_r++;
    if (rvalid && rready && rlast) outstanding--;
    chk(outstanding >= 0 && outstanding <= 4, "bounded outstanding bursts");
    ar_was_stalled = arvalid && !arready; held_araddr = araddr; held_arlen = arlen;
  end

  // AXI read model with queued requests and random stalls.
  // Addresses with bit 40 set return SLVERR for the whole burst.
  logic [127:0] ddr [longint unsigned];      // Indexed by byte address >> 4.
  typedef struct { logic [47:0] addr; logic [7:0] len; } ar_t;
  ar_t arq[$];

  int ar_stall;
  bit force_ar_block = 0;
  bit ddr_fast = 0;  // Remove random DDR stalls for fast error responses.
  always @(posedge maxi_clk) ar_stall <= $urandom_range(0, 9);
  assign arready = maxi_rstn && !force_ar_block && (ddr_fast || ar_stall != 0);
  always @(posedge maxi_clk) if (arvalid && arready) begin
    ar_t a;
    chk(arsize === 3'd4, "AXI ARSIZE must select 16-byte beats");
    chk(arburst === 2'b01, "AXI ARBURST must be INCR");
    a.addr = araddr;
    a.len = arlen;
    arq.push_back(a);
  end

  initial begin
    rvalid = 0; rdata = '0; rresp = 2'b00; rlast = 0; rid = '0;
    wait (maxi_rstn);
    forever begin
      @(posedge maxi_clk);
      if (arq.size() > 0) begin
        automatic ar_t a = arq.pop_front();
        for (int b = 0; b <= a.len; b++) begin
          while (!ddr_fast && $urandom_range(0, 3) == 0) @(posedge maxi_clk);
          rvalid <= 1;
          rdata  <= ddr.exists((a.addr >> 4) + b) ? ddr[(a.addr >> 4) + b] : '0;
          rresp  <= a.addr[40] ? 2'b10 : 2'b00;
          rlast  <= (b == a.len);
          @(posedge maxi_clk);
          while (!rready) @(posedge maxi_clk);
          rvalid <= 0; rlast <= 0;
        end
      end
    end
  end

  // LVDS sinks: random backpressure, per-port blocking and packet capture.
  logic [NP-1:0] port_block;
  logic [95:0]   got_d [NP][$];
  time           got_t [NP][$];
  always @(posedge maxi_clk) for (int p = 0; p < NP; p++)
    lv_tx_tready[p] <= maxi_rstn && !port_block[p] && ($urandom_range(0, 3) != 0);
  always @(posedge maxi_clk) for (int p = 0; p < NP; p++)
    if (lv_tx_tvalid[p] && lv_tx_tready[p]) begin
      got_d[p].push_back(lv_tx_tdata[p]);
      got_t[p].push_back($time);
    end

  // Host APB transactions.
  task automatic apb_wr(input [15:0] a, input [31:0] d);
    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 1; paddr <= a; pwdata <= d;
    @(posedge pclk); penable <= 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    chk(!pslverr, $sformatf("APB 写 %04x pslverr", a));
    psel <= 0; penable <= 0; @(posedge pclk);
  endtask
  task automatic apb_rd(input [15:0] a, output [31:0] d);
    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 0; paddr <= a;
    @(posedge pclk); penable <= 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    d = prdata;
    chk(!pslverr, $sformatf("APB 读 %04x pslverr", a));
    psel <= 0; penable <= 0; @(posedge pclk);
  endtask

  // Record tables and expected packets.
  localparam longint unsigned TBL_BASE = 64'h0000_1000_0000;   // 64-byte-aligned record table.
  // AXI error region: address bit 40 set.
  localparam longint unsigned ERR_BASE = 64'h100_0000_0000;

  logic [95:0] exp_d [NP][$];
  int unsigned exp_sent;
  bit          exp_err;

  function automatic logic [127:0] mk_rec(input [15:0] tag, input [7:0] flags,
                                          input [7:0] ch, input [95:0] pkt);
    return {tag, flags, ch, pkt};
  endfunction

  // Build expected packets using the testbench channel configuration.
  logic [11:0] sh_en;
  logic [47:0] sh_remap;   // Four bits per logical channel.
  function automatic void gold_rec(input logic [127:0] r);
    logic [7:0] ch; logic [3:0] phys; int port;
    ch = r[103:96];
    if (ch > 8'd11)                begin exp_err = 1; return; end
    if (!sh_en[ch[3:0]])           begin exp_err = 1; return; end
    phys = sh_remap[4*ch[3:0] +: 4];
    if (phys >= 4'(TEST_N_CH))       begin exp_err = 1; return; end
    port = (int'(phys) / 3) * 4 + (int'(phys) % 3);
    exp_d[port].push_back(r[95:0]);
    exp_sent++;
  endfunction

  task automatic clr_expect();
    for (int p = 0; p < NP; p++) begin exp_d[p].delete(); got_d[p].delete(); got_t[p].delete(); end
    exp_sent = 0; exp_err = 0;
  endtask

  // Load DDR and build expected packets through the first LAST record.
  task automatic load_table(input longint unsigned base, input logic [127:0] recs[$]);
    bit stopped = 0;
    foreach (recs[i]) begin
      ddr[(base >> 4) + i] = recs[i];
      if (!stopped) begin
        gold_rec(recs[i]);
        if ((recs[i][111:104] & REC_LAST) != 8'h00) stopped = 1;
      end
    end
  endtask

  // Start immediately after programming configuration.
  task automatic start_table(input longint unsigned base, input int unsigned cnt);
    apb_wr(A_SRC_LO, base[31:0]);
    apb_wr(A_SRC_HI, {16'h0, base[47:32]});
    apb_wr(A_CNT, cnt);
    apb_wr(A_DB, 32'h1);
  endtask

  int unsigned poll_skew = 0;  // Delay polling by this many pclk cycles.
  // Start a table and check completion, status, count and packets.
  task automatic run_table(input longint unsigned base, input int unsigned cnt,
                           input string tag);
    logic [31:0] v;
    start_table(base, cnt);
    repeat (poll_skew) @(posedge pclk);
    // Poll for task completion.
    v = 0;
    for (int t = 0; t < apb_poll_limit(20000); t++) begin
      apb_rd(A_STA, v);
      if (v[8]) break;                       // DONE
    end
    chk(v[8], {tag, ": DONE 超时"});
    chk(!v[0], {tag, ": DONE 后 BUSY 仍在"});
    chk(v[9] == exp_err, $sformatf("%s: ERR=%b 预期 %b", tag, v[9], exp_err));
    wait_sent(exp_sent, tag);
    apb_wr(A_STA, 32'h0000_0300);            // W1C DONE+ERR
    check_ports(tag);
  endtask

  // Compare packet count, content and order on each port.
  task automatic check_ports(input string tag);
    for (int p = 0; p < NP; p++) begin
      chk(got_d[p].size() == exp_d[p].size(),
          $sformatf("%s: 口%0d 收 %0d 预期 %0d", tag, p, got_d[p].size(), exp_d[p].size()));
      for (int i = 0; i < got_d[p].size() && i < exp_d[p].size(); i++)
        chk(got_d[p][i] === exp_d[p][i],
            $sformatf("%s: 口%0d 包%0d %h!=%h", tag, p, i, got_d[p][i], exp_d[p][i]));
    end
  endtask

  function automatic logic [95:0] rnd_pkt();
    return {$urandom, $urandom, $urandom};
  endfunction

  // Check only the packets already presented when P9 requests abort.
  bit p9_watch = 0, p9_hold_ok, p9_no_refill;
  logic [NP-1:0] p9_pending;
  always @(posedge maxi_clk) if (p9_watch) begin
    for (int p = 0; p < NP; p++) begin
      if (p9_pending[p]) begin
        if (lv_tx_tvalid[p] !== 1'b1 || lv_tx_tdata[p] !== exp_d[p][0])
          p9_hold_ok = 0;
        if (lv_tx_tvalid[p] && lv_tx_tready[p]) p9_pending[p] = 0;
      end else if (lv_tx_tvalid[p] !== 1'b0) begin
        p9_no_refill = 0;
      end
    end
  end

  // SENT may lag packet acceptance while a snapshot crosses to pclk.
  task automatic wait_sent(input int unsigned expected, input string tag);
    logic [31:0] value;
    // Allow an in-flight snapshot to finish before polling the expected count.
    repeat (12) begin
      @(negedge maxi_clk);
      @(negedge pclk);
    end
    for (int t = 0; t < apb_poll_limit(2000); t++) begin
      apb_rd(A_SENT, value);
      if (value === expected) break;
    end
    chk(value === expected,
        $sformatf("%s: SENT=%0d, expected %0d", tag, value, expected));
  endtask

  // Test sequence.
  logic [127:0] recs[$];
  logic [31:0]  v, v2;
  int           n_img;
  string        img_path;
  int           fd;
  logic [7:0]   img_bytes [0:(1<<22)-1];   // Static 4 MiB buffer for $fread.
  time          t_pre_max;

  initial begin
    $display("CLOCK half-periods: pclk=%0.3f ns maxi=%0.3f ns", pclk_hp, maxi_hp);
    psel = 0; penable = 0; pwrite = 0; paddr = '0; pwdata = '0;
    port_block = '0;
    sh_en = 12'h007; sh_remap = 48'hBA98_7654_3210;
    #(200ns * clock_scale());
    presetn = 1; maxi_rstn = 1;
    #(200ns * clock_scale());

    // P1: Send 60 mixed-channel records under random backpressure.
    clr_expect();
    apb_wr(A_LNK_EN, 32'h007);
    recs.delete();
    // No record IRQ: RAW[9] must be set by task completion.
    for (int i = 0; i < 60; i++)
      recs.push_back(mk_rec(16'(i), (i == 59) ? REC_LAST : 8'h0,
                            8'($urandom_range(0, 2)), rnd_pkt()));
    load_table(TBL_BASE, recs);
    run_table(TBL_BASE, 60, "P1");
    apb_rd(A_IRQ_RAW, v);
    chk(v[9], "P1: RAW[9] 完成事件");
    apb_wr(A_IRQ_RAW, 32'h0000_0200);
    $display("P1 done (%0d checks, %0d errs)", checks, errs);

    // P2: Replay a record image supplied with +IMG.
    if ($value$plusargs("IMG=%s", img_path)) begin
      clr_expect();
      fd = $fopen(img_path, "rb");
      chk(fd != 0, "P2: 镜像打开失败");
      if (fd != 0) begin
        int n;
        n = $fread(img_bytes, fd);
        $fclose(fd);
        n_img = n / 16;
        chk(n_img > 0 && (n % 16) == 0, $sformatf("P2: 镜像 %0d 字节非 16B 整数倍", n));
        recs.delete();
        for (int i = 0; i < n_img; i++) begin
          logic [127:0] r;
          // Little-endian 16-byte records.
          for (int b = 0; b < 16; b++) r[8*b +: 8] = img_bytes[i*16 + b];
          recs.push_back(r);
        end
        load_table(TBL_BASE, recs);
        run_table(TBL_BASE, n_img, "P2");
        $display("P2 done: %0d 镜像记录重放 (%0d checks, %0d errs)", n_img, checks, errs);
      end
    end else begin
      $display("P2 skip(无 +IMG)");
    end

    // P3: Block one packet on port 0; FENCE must delay the next packet on port 1.
    clr_expect();
    port_block[0] = 1'b1;
    recs.delete();
    recs.push_back(mk_rec(16'h0, 8'h0, 8'd0, rnd_pkt()));
    recs.push_back(mk_rec(16'h100, REC_FENCE, 8'd1, rnd_pkt()));
    for (int i = 0; i < 2; i++) recs.push_back(mk_rec(16'(i), 8'h0, 8'd1, rnd_pkt()));
    recs.push_back(mk_rec(16'hFFF, REC_LAST, 8'd2, rnd_pkt()));
    load_table(TBL_BASE, recs);
    start_table(TBL_BASE, recs.size());
    #(3us * clock_scale());                 // Hold port 0 while FENCE is pending.
    chk(got_d[1].size() == 0, "P3: fence 前口1 不得先行");
    port_block[0] = 1'b0;
    for (int t = 0; t < apb_poll_limit(2000); t++) begin apb_rd(A_STA, v); if (v[8]) break; end
    chk(v[8], "P3: DONE 超时");
    apb_wr(A_STA, 32'h300);
    t_pre_max = 0;
    foreach (got_t[0][i]) if (got_t[0][i] > t_pre_max) t_pre_max = got_t[0][i];
    chk(got_d[1].size() > 0 && got_t[1][0] > t_pre_max,
        "P3: fence 包接受时刻晚于全部前序包");
    check_ports("P3");
    $display("P3 done (%0d checks, %0d errs)", checks, errs);

    // P4: Stop at record 13 marked LAST, with CNT set to 20.
    clr_expect();
    recs.delete();
    for (int i = 0; i < 20; i++)
      recs.push_back(mk_rec(16'(i), (i == 12) ? REC_LAST : 8'h0,
                            8'($urandom_range(0, 2)), rnd_pkt()));
    load_table(TBL_BASE, recs);
    run_table(TBL_BASE, 20, "P4");
    chk(exp_sent == 13, "P4: 金标准自检(13 条)");
    $display("P4 done (%0d checks, %0d errs)", checks, errs);

    // P5: Report the sixth record IRQ while the task is still busy.
    clr_expect();
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);       // Clear pending IRQ events.
    recs.delete();
    for (int i = 0; i < 400; i++)
      recs.push_back(mk_rec(16'(i), (i == 5) ? REC_IRQ
                                  : (i == 399) ? REC_LAST : 8'h0,
                            8'($urandom_range(0, 2)), rnd_pkt()));
    load_table(TBL_BASE, recs);
    start_table(TBL_BASE, 400);
    v2 = 0;
    for (int t = 0; t < apb_poll_limit(5000); t++) begin
      apb_rd(A_IRQ_RAW, v);
      if (v[9]) begin apb_rd(A_GLB_STA, v2); break; end
    end
    chk(v[9], "P5: RAW[9] irq 标志事件");
    chk(v2[9], "P5: irq 到达时 GLB.STA.SEND_BUSY 仍在(证明中途报)");
    for (int t = 0; t < apb_poll_limit(5000); t++) begin apb_rd(A_STA, v); if (v[8]) break; end
    chk(v[8], "P5: DONE 超时");
    apb_wr(A_STA, 32'h300); apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    check_ports("P5");
    $display("P5 done (%0d checks, %0d errs)", checks, errs);

    // P6: Disable channel 1 and include an invalid channel 13 record.
    clr_expect();
    apb_wr(A_LNK_EN, 32'h005);  sh_en = 12'h005;
    recs.delete();
    for (int i = 0; i < 30; i++)
      recs.push_back(mk_rec(16'(i), 8'h0, 8'($urandom_range(0, 2)), rnd_pkt()));
    recs.push_back(mk_rec(16'h666, 8'h0, 8'd13, rnd_pkt()));      // Invalid channel.
    recs.push_back(mk_rec(16'h667, REC_LAST, 8'd0, rnd_pkt()));
    load_table(TBL_BASE, recs);
    run_table(TBL_BASE, recs.size(), "P6");
    chk(exp_err, "P6: 金标准自检(应有 ERR)");
    apb_wr(A_LNK_EN, 32'h007);  sh_en = 12'h007;
    $display("P6 done (%0d checks, %0d errs)", checks, errs);

    // P7: Swap channel 0 and channel 2 mappings.
    clr_expect();
    apb_wr(A_REMAP0, 32'h7654_3012);  sh_remap = 48'hBA98_7654_3012;
    recs.delete();
    for (int i = 0; i < 24; i++)
      recs.push_back(mk_rec(16'(i), (i == 23) ? REC_LAST : 8'h0,
                            8'($urandom_range(0, 2)), rnd_pkt()));
    load_table(TBL_BASE, recs);
    run_table(TBL_BASE, 24, "P7");
    apb_wr(A_REMAP0, 32'h7654_3210);  sh_remap = 48'hBA98_7654_3210;
    $display("P7 done (%0d checks, %0d errs)", checks, errs);

    // P8: Abort on an AXI read error, then start another task.
    clr_expect();
    recs.delete();
    for (int i = 0; i < 10; i++)
      recs.push_back(mk_rec(16'(i), 8'h0, 8'd0, rnd_pkt()));
    // No packets expected from failed reads.
    foreach (recs[i]) ddr[(ERR_BASE >> 4) + i] = recs[i];
    exp_err = 1;                                                  // Expect the AXI read error.
    run_table(ERR_BASE, 10, "P8a");
    chk(exp_sent == 0, "P8a: 金标准自检(0 发送)");
    // Check that a new task can report an error after an AXI failure.
    clr_expect();
    recs.delete();
    for (int i = 0; i < 4; i++)
      recs.push_back(mk_rec(16'(i), 8'h0, 8'($urandom_range(0, 2)), rnd_pkt()));
    // Invalid channel must report an error.
    recs.push_back(mk_rec(16'h666, 8'h0, 8'd13, rnd_pkt()));
    for (int i = 0; i < 3; i++)
      recs.push_back(mk_rec(16'(4 + i), (i == 2) ? REC_LAST : 8'h0,
                            8'($urandom_range(0, 2)), rnd_pkt()));
    load_table(TBL_BASE, recs);
    run_table(TBL_BASE, recs.size(), "P8b");
    chk(exp_err, "P8b: 金标准自检(应有 ERR)");
    $display("P8 done (%0d checks, %0d errs)", checks, errs);

    // P9: Abort with pending packets, drain each port, then restart.
    clr_expect();
    port_block = 4'hF;
    apb_wr(A_STA, 32'h300);
    apb_wr(A_IRQ_RAW, 32'h200);
    recs.delete();
    // The first three records occupy ports 0..2; only the third requests IRQ.
    for (int i = 0; i < 50; i++) begin
      recs.push_back(mk_rec(16'(i), (i == 2) ? REC_IRQ : 8'h00,
                            8'(i % 3), rnd_pkt()));
      ddr[(TBL_BASE >> 4) + i] = recs[i];
      if (i < 3) gold_rec(recs[i]);
    end
    start_table(TBL_BASE, 50);
    for (int t = 0; t < 2000; t++) begin
      @(negedge maxi_clk);
      if (lv_tx_tvalid === 4'h7) break;
    end
    chk(lv_tx_tvalid === 4'h7, "P9: packets pending on all three ports");
    p9_pending = 4'h7;
    p9_hold_ok = 1;
    p9_no_refill = 1;
    p9_watch = 1;
    wait_sent(0, "P9 blocked");
    apb_rd(A_STA, v); chk(v[0] && !v[8] && !v[9], "P9: busy before abort");
    apb_rd(A_IRQ_RAW, v); chk(!v[9], "P9: no IRQ before packet acceptance");
    apb_wr(A_GLB_CTRL, 32'h1);

    // Allow the abort to cross clock domains while all outputs remain blocked.
    repeat (12) @(negedge maxi_clk);
    repeat (12) @(negedge pclk);
    apb_rd(A_STA, v);
    chk(v[0] && !v[8] && !v[9], "P9: abort retains BUSY without DONE or ERR");
    for (int p = 0; p < NP; p++)
      chk(got_d[p].size() == 0, $sformatf("P9: port %0d still blocked", p));

    // Drain the IRQ-marked packet last; earlier packets must not raise IRQ.
    for (int p = 0; p < 3; p++) begin
      @(negedge maxi_clk); port_block[p] = 0;
      for (int t = 0; t < 2000; t++) begin
        @(negedge maxi_clk);
        if (got_d[p].size() != 0) break;
      end
      chk(got_d[p].size() == 1, $sformatf("P9: port %0d drains one packet", p));
      wait_sent(p + 1, "P9 drain");
      if (p < 2) begin
        apb_rd(A_STA, v);
        chk(v[0] && !v[8] && !v[9], "P9: BUSY until all pending packets drain");
        apb_rd(A_IRQ_RAW, v); chk(!v[9], "P9: unmarked packets do not raise IRQ");
      end
    end
    for (int t = 0; t < apb_poll_limit(2000); t++) begin
      apb_rd(A_STA, v);
      if (!v[0]) break;
    end
    chk(!v[0] && !v[8] && !v[9], "P9: idle after draining, no DONE or ERR");
    apb_rd(A_IRQ_RAW, v); chk(v[9], "P9: IRQ-marked packet reports during abort drain");
    repeat (16) @(negedge maxi_clk);
    chk(p9_pending === '0, "P9: every pending packet accepted");
    chk(p9_hold_ok, "P9: pending VALID and payload held until acceptance");
    chk(p9_no_refill, "P9: no new packets after abort");
    check_ports("P9a");
    p9_watch = 0;
    port_block = '0;
    apb_wr(A_IRQ_RAW, 32'h200);
    clr_expect();
    recs.delete();
    for (int i = 0; i < 8; i++)
      recs.push_back(mk_rec(16'(i), (i == 7) ? REC_LAST : 8'h0,
                            8'($urandom_range(0, 2)), rnd_pkt()));
    load_table(TBL_BASE, recs);
    run_table(TBL_BASE, 8, "P9b");
    $display("P9 done (%0d checks, %0d errs)", checks, errs);

    // P10: Boundary split: 4 + 64 + 64 + 9 records, followed by an empty job.
    clr_expect(); apb_wr(A_LNK_EN, 7); recs.delete();
    for (int i=0; i<141; i++) recs.push_back(mk_rec(16'(i), 0, 8'(i%3), rnd_pkt()));
    load_table(48'h10000FC0, recs);
    watch_boundary = 1; boundary_requests = 0; max_outstanding = 0;
    run_table(48'h10000FC0, 141, "BOUNDARY");
    watch_boundary = 0;
    chk(boundary_requests == 4 && max_outstanding > 1, "boundary split and multiple outstanding exercised");
    ar0 = total_ar;
    clr_expect(); run_table(TBL_BASE, 0, "EMPTY");
    chk(total_ar == ar0, "EMPTY: no memory request");

    // P11: Retain a stalled AR after abort, then drain the accepted burst.
    clr_expect(); apb_wr(A_IRQ_RAW, 32'hFFFFFFFF);
    for (int i=0; i<128; i++) ddr[(TBL_BASE>>4)+i] = mk_rec(16'(i),0,0,rnd_pkt());
    ar0 = total_ar; r0 = total_r; force_ar_block = 1;
    start_table(TBL_BASE, 128);
    for (int i=0; i<2000; i++) begin @(negedge maxi_clk); if (arvalid) break; end
    chk(arvalid && !arready, "ABORT_AR: pending request exists");
    repeat (8) @(negedge maxi_clk);
    apb_wr(A_GLB_CTRL,1);
    repeat (12) @(negedge maxi_clk);
    repeat (12) @(negedge pclk);
    chk(arvalid && !arready && total_ar==ar0, "ABORT_AR: stalled request retained after abort");
    apb_rd(A_STA,v); chk(v[0] && !v[8] && !v[9], "ABORT_AR: remains busy without completion");
    force_ar_block = 0;
    for (int i=0; i<apb_poll_limit(2000); i++) begin apb_rd(A_STA,v); if (!v[0]) break; end
    chk(!v[0] && !v[8] && !v[9], "ABORT_AR: returns idle after draining");
    chk(total_ar==ar0+1 && total_r==r0+64 && outstanding==0, "ABORT_AR: drains exactly the committed burst");
    for (int p=0; p<NP; p++) chk(got_d[p].size()==0, "ABORT_AR: no packets transmitted");
    // P12: LAST in the first burst; drain all later outstanding reads.
    clr_expect(); recs.delete();
    for (int i=0; i<300; i++) recs.push_back(mk_rec(16'(i), (i==4)?REC_LAST:8'h00, 8'(i%3),rnd_pkt()));
    load_table(TBL_BASE,recs); run_table(TBL_BASE,300,"EARLY_LAST_MULTIBURST");
    chk(exp_sent==5 && outstanding==0,"EARLY_LAST_MULTIBURST: five outputs and all reads drained");
    $display("P10-P12 done (%0d checks, %0d errs)", checks, errs);

    // P13: Consecutive error and IRQ tasks, polling phases and recovery.
    // Each fast AXI failure must raise a new error event.
    ddr_fast = 1'b1;
    for (int k = 0; k < 3; k++) begin
      clr_expect();
      apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
      recs.delete();
      recs.push_back(mk_rec(16'(k), REC_LAST, 8'd0, rnd_pkt()));
      foreach (recs[i]) ddr[(ERR_BASE >> 4) + i] = recs[i];
      exp_err = 1;
      run_table(ERR_BASE, 1, $sformatf("P13.%0d", k));
      apb_rd(A_IRQ_RAW, v);
      chk(v[28], $sformatf("P13.%0d: each AXI error task sets RAW[28]", k));
    end
    // Invalid records report errors while valid records continue.
    for (int k = 0; k < 2; k++) begin
      clr_expect();
      recs.delete();
      recs.push_back(mk_rec(16'h666, 8'h0, 8'd13, rnd_pkt()));
      recs.push_back(mk_rec(16'h667, REC_LAST, 8'd0, rnd_pkt()));
      load_table(TBL_BASE, recs);
      run_table(TBL_BASE, recs.size(), $sformatf("P13r.%0d", k));
      chk(exp_err, "P13r: test input must require ERR");
    end
    // Check ERR in the first DONE read at all four APB polling phases.
    for (int k = 0; k < 8; k++) begin
      clr_expect();
      apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
      poll_skew = k % 4;
      recs.delete();
      if (k < 4) begin
        recs.push_back(mk_rec(16'(k), REC_LAST, 8'd0, rnd_pkt()));
        foreach (recs[i]) ddr[(ERR_BASE >> 4) + i] = recs[i];
        exp_err = 1;
        run_table(ERR_BASE, 1, $sformatf("P13s.%0d(AXI error, phase %0d)", k, poll_skew));
        apb_rd(A_IRQ_RAW, v);
        chk(v[28], $sformatf("P13s.%0d: RAW[28]", k));
      end else begin
        recs.push_back(mk_rec(16'h666, 8'h0, 8'd13, rnd_pkt()));
        recs.push_back(mk_rec(16'h667, REC_LAST, 8'd0, rnd_pkt()));
        load_table(TBL_BASE, recs);
        run_table(TBL_BASE, recs.size(), $sformatf("P13s.%0d(invalid record, phase %0d)", k, poll_skew));
        chk(exp_err, "P13s: test input must require ERR");
      end
    end
    // A successful task must not inherit a previous task's error.
    poll_skew = 0;
    clr_expect();
    recs.delete();
    recs.push_back(mk_rec(16'h0, REC_LAST, 8'd0, rnd_pkt()));
    foreach (recs[i]) ddr[(ERR_BASE >> 4) + i] = recs[i];
    exp_err = 1;
    run_table(ERR_BASE, 1, "P13c.0(AXI error)");
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    clr_expect();
    recs.delete();
    for (int i = 0; i < 6; i++)
      recs.push_back(mk_rec(16'(i), (i == 5) ? REC_LAST : 8'h0,
                            8'($urandom_range(0, 2)), rnd_pkt()));
    load_table(TBL_BASE, recs);
    run_table(TBL_BASE, 6, "P13c.1(valid table)");
    repeat (16) @(posedge pclk);
    apb_rd(A_STA, v);
    chk(!v[9], "P13c: ERR remains clear after a valid task");
    apb_rd(A_IRQ_RAW, v);
    chk(!v[28], "P13c: valid task keeps RAW[28] clear");
    // Each task must report its record IRQ before completion.
    for (int k = 0; k < 2; k++) begin
      clr_expect();
      apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
      recs.delete();
      for (int i = 0; i < 400; i++)
        recs.push_back(mk_rec(16'(i), (i == 0) ? REC_IRQ
                                    : (i == 399) ? REC_LAST : 8'h0,
                              8'($urandom_range(0, 2)), rnd_pkt()));
      load_table(TBL_BASE, recs);
      apb_wr(A_SRC_LO, TBL_BASE[31:0]); apb_wr(A_SRC_HI, {16'h0, TBL_BASE[47:32]});
      apb_wr(A_CNT, 400); apb_wr(A_DB, 32'h1);
      v2 = 0;
      for (int t = 0; t < 5000; t++) begin
        apb_rd(A_IRQ_RAW, v);
        if (v[9]) begin apb_rd(A_GLB_STA, v2); break; end
      end
      chk(v[9], $sformatf("P13i.%0d: IRQ-marked record sets RAW[9]", k));
      chk(v2[9], $sformatf("P13i.%0d: SEND is still busy when the record IRQ arrives", k));
      v = 0;
      for (int t = 0; t < apb_poll_limit(20000); t++) begin
        apb_rd(A_STA, v);
        if (v[8]) break;
      end
      chk(v[8], $sformatf("P13i.%0d: DONE timeout", k));
      apb_wr(A_STA, 32'h300);
      check_ports($sformatf("P13i.%0d", k));
    end
    // Restore random DDR stalls and check normal task completion.
    ddr_fast = 1'b0;
    clr_expect();
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    recs.delete();
    for (int i = 0; i < 6; i++)
      recs.push_back(mk_rec(16'(i), (i == 5) ? REC_LAST : 8'h0,
                            8'($urandom_range(0, 2)), rnd_pkt()));
    load_table(TBL_BASE, recs);
    run_table(TBL_BASE, 6, "P13b");
    $display("P13 done (%0d checks, %0d errs)", checks, errs);

    if (errs == 0 && checks > 0) $display("SEND TB PASS (%0d checks)", checks);
    else           $display("SEND TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end

  initial begin #(8ms * clock_scale()); $display("SEND TB TIMEOUT"); $finish; end

endmodule
