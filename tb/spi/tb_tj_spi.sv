// File        : tb_tj_spi.sv
// Module      : tb_tj_spi
// Description : SPI engine and subsystem regression against the chip spi2ahb model.
// T1/T2: Single-word doorbell access and shared-bus isolation.
// T3/T4: 16-word transfers, source stalls, read backpressure and AHB waits.
// T5/T6: CS timing and the minimum SCLK divider.
// T7: Timeout recovery. T8/T9: SPIWIN access and arbitration.
// T10/T11: Group 7 doorbell access and SPIWIN timeout recovery.
// T12: Command gating while a read result is pending.
// T13: Cross-access to die31 through doorbell and SPIWIN.
// T14: Independent group 0/7 dividers and watchdog settings.
// Compile with -timescale=1ns/1ps.

// AHB RAM with random or fixed wait states.
module ahb_ram_beh (
  input  logic        hclk,
  input  logic        hresetn,
  input  logic [31:0] haddr,
  input  logic [ 2:0] hburst,
  input  logic [ 2:0] hsize,
  input  logic [ 1:0] htrans,
  input  logic [31:0] hwdata,
  input  logic        hwrite,
  output logic [31:0] hrdata,
  output logic        hready,
  output logic        hresp
);
  logic [31:0] mem [0:4095];              // 16KB
  logic        ap_v;
  logic [31:0] ap_a;
  logic        ap_w;
  logic [2:0]  wait_q;
  int          force_ws = -1;             // ≥0 = 每拍固定等待数(定向最坏用例);<0 = 随机 0..2

  assign hresp  = 1'b0;
  assign hready = (wait_q == 3'd0);
  assign hrdata = (ap_v && !ap_w) ? mem[ap_a[13:2]] : '0;

  always @(posedge hclk or negedge hresetn) begin
    if (!hresetn) begin
      ap_v <= 1'b0; ap_a <= '0; ap_w <= 1'b0; wait_q <= '0;
    end else begin
      if (hready) begin
        if (ap_v && ap_w) mem[ap_a[13:2]] <= hwdata;
        ap_v <= htrans[1];
        ap_a <= haddr;
        ap_w <= hwrite;
        if (htrans[1]) wait_q <= (force_ws >= 0) ? 3'(force_ws) : 3'($urandom_range(0, 2));
      end else begin
        wait_q <= wait_q - 3'd1;
      end
    end
  end

`ifdef SPI_TB_DBG
  always @(posedge hclk)
    if (hready && ap_v && ap_w) $display("DBG %m wr [%03x]=%08x @%0t", ap_a[13:2], hwdata, $time);
`endif
endmodule

// ---------------- TB 顶层 ----------------
module tb_tj_spi;
  `include "tj_case_select.svh"
  import tj_ctrl_pkg::*;
  import tj_ctrl_csr_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;                    // 100MHz(pclk=hclk)

  int unsigned errs = 0, checks = 0;
  string cur_test = "init";
  int t4_k = -1;
  task automatic chk(input bit c, input string m);
    checks++;
    if (!c) begin errs++; $display("FAIL: %s @%0t", m, $time); end
  endtask

  // ==========================================================================
  // A. 子系统 DUT(门铃/SPIWIN/仲裁;组0 的 die0/die1 挂两份芯片从机)
  // ==========================================================================
  tj_csr_o_t hwo;
  logic [7:0][31:0] s_rdata;
  logic [7:0] s_busy, s_done, s_err;
  logic sw_busy, sw_err;
  logic wp_sel, wp_en, wp_wr;
  logic [11:0] wp_addr;
  logic [31:0] wp_wdata, wp_rdata;
  logic wp_rdy, wp_slv;
  logic [7:0] ss_sclk, ss_mosi;
  logic [31:0] ss_cs, ss_miso;

  tj_spi_subsys u_ss (
    .pclk(clk), .presetn(rst_n), .hwo(hwo),
    .spi_rdata_o(s_rdata), .spi_busy_o(s_busy),
    .spi_done_set_o(s_done), .spi_err_set_o(s_err),
    .spiwin_busy_o(sw_busy), .spiwin_err_set_o(sw_err),
    // BOOT port is unused in this test.
    .bt_cmd_valid(1'b0), .bt_cmd_ready(),
    .bt_die(5'h0), .bt_kind(2'h0), .bt_addr(32'h0),
    .bt_wdat_valid(1'b0), .bt_wdat_ready(), .bt_wdat(32'h0),
    .bt_rdat_valid(), .bt_rdat_ready(1'b1), .bt_rdat(),
    .bt_done(), .bt_err(),
    .win_psel(wp_sel), .win_penable(wp_en), .win_pwrite(wp_wr),
    .win_paddr(wp_addr), .win_pwdata(wp_wdata),
    .win_pready(wp_rdy), .win_pslverr(wp_slv), .win_prdata(wp_rdata),
    .spi_sclk(ss_sclk), .spi_mosi(ss_mosi), .spi_cs_n(ss_cs), .spi_miso(ss_miso)
  );

  // 芯片从机 ×2(die0/die1 共享组0 的 sclk/mosi)
  logic [31:0] h0_haddr, h0_hwdata, h0_hrdata;
  logic [2:0]  h0_hburst, h0_hsize;
  logic [1:0]  h0_htrans;
  logic        h0_hwrite, h0_hready, h0_hresp, h0_lock;
  logic [3:0]  h0_hprot;
  logic        miso0;
  spi2ahb u_chip0 (
    .spi_cs_n(ss_cs[0]), .spi_sck(ss_sclk[0]), .spi_mosi(ss_mosi[0]), .spi_miso(miso0),
    .hclk(clk), .hresetn(rst_n),
    .hrdata(h0_hrdata), .hready(h0_hready), .hresp(h0_hresp),
    .haddr(h0_haddr), .hburst(h0_hburst), .hmastlock(h0_lock), .hprot(h0_hprot),
    .hsize(h0_hsize), .htrans(h0_htrans), .hwdata(h0_hwdata), .hwrite(h0_hwrite)
  );
  ahb_ram_beh u_ram0 (
    .hclk(clk), .hresetn(rst_n),
    .haddr(h0_haddr), .hburst(h0_hburst), .hsize(h0_hsize), .htrans(h0_htrans),
    .hwdata(h0_hwdata), .hwrite(h0_hwrite),
    .hrdata(h0_hrdata), .hready(h0_hready), .hresp(h0_hresp)
  );

  logic [31:0] h1_haddr, h1_hwdata, h1_hrdata;
  logic [2:0]  h1_hburst, h1_hsize;
  logic [1:0]  h1_htrans;
  logic        h1_hwrite, h1_hready, h1_hresp, h1_lock;
  logic [3:0]  h1_hprot;
  logic        miso1;
  spi2ahb u_chip1 (
    .spi_cs_n(ss_cs[1]), .spi_sck(ss_sclk[0]), .spi_mosi(ss_mosi[0]), .spi_miso(miso1),
    .hclk(clk), .hresetn(rst_n),
    .hrdata(h1_hrdata), .hready(h1_hready), .hresp(h1_hresp),
    .haddr(h1_haddr), .hburst(h1_hburst), .hmastlock(h1_lock), .hprot(h1_hprot),
    .hsize(h1_hsize), .htrans(h1_htrans), .hwdata(h1_hwdata), .hwrite(h1_hwrite)
  );
  ahb_ram_beh u_ram1 (
    .hclk(clk), .hresetn(rst_n),
    .haddr(h1_haddr), .hburst(h1_hburst), .hsize(h1_hsize), .htrans(h1_htrans),
    .hwdata(h1_hwdata), .hwrite(h1_hwrite),
    .hrdata(h1_hrdata), .hready(h1_hready), .hresp(h1_hresp)
  );

  // 芯片从机 ×1(组 7 的 die31:验证 grp_id 3bit 全宽与最高组通路)
  logic [31:0] h3_haddr, h3_hwdata, h3_hrdata;
  logic [2:0]  h3_hburst, h3_hsize;
  logic [1:0]  h3_htrans;
  logic        h3_hwrite, h3_hready, h3_hresp, h3_lock;
  logic [3:0]  h3_hprot;
  logic        miso3;
  spi2ahb u_chip3 (
    .spi_cs_n(ss_cs[31]), .spi_sck(ss_sclk[7]), .spi_mosi(ss_mosi[7]), .spi_miso(miso3),
    .hclk(clk), .hresetn(rst_n),
    .hrdata(h3_hrdata), .hready(h3_hready), .hresp(h3_hresp),
    .haddr(h3_haddr), .hburst(h3_hburst), .hmastlock(h3_lock), .hprot(h3_hprot),
    .hsize(h3_hsize), .htrans(h3_htrans), .hwdata(h3_hwdata), .hwrite(h3_hwrite)
  );
  ahb_ram_beh u_ram3 (
    .hclk(clk), .hresetn(rst_n),
    .haddr(h3_haddr), .hburst(h3_hburst), .hsize(h3_hsize), .htrans(h3_htrans),
    .hwdata(h3_hwdata), .hwrite(h3_hwrite),
    .hrdata(h3_hrdata), .hready(h3_hready), .hresp(h3_hresp)
  );

  always_comb begin
    ss_miso     = '0;
    ss_miso[0]  = miso0;
    ss_miso[1]  = miso1;
    ss_miso[31] = miso3;
  end

  // Count each group's completion and error events separately.
  int unsigned s_done_count[8] = '{default:0};
  int unsigned s_error_count[8] = '{default:0};
  int unsigned sw_error_count = 0;
  int unsigned clk_cycles = 0;
  always @(posedge clk) if (rst_n) begin
    clk_cycles++;
    for (int g = 0; g < 8; g++) begin
      if (s_done[g]) s_done_count[g]++;
      if (s_err[g]) s_error_count[g]++;
    end
    if (sw_err) sw_error_count++;
  end

  // Measure the shortest SCLK period within a selected frame, in clk cycles.
  int sclk_last_cycle[8] = '{default:-1};
  int sclk_min_cycles[8] = '{default:32'h7FFF_FFFF};
  for (genvar g = 0; g < 8; g++) begin : g_sclk_measure
    always @(posedge ss_sclk[g]) if (rst_n && !(&ss_cs[g*4 +: 4])) begin
      if (sclk_last_cycle[g] >= 0 &&
          clk_cycles - sclk_last_cycle[g] < sclk_min_cycles[g])
        sclk_min_cycles[g] = clk_cycles - sclk_last_cycle[g];
      sclk_last_cycle[g] = clk_cycles;
    end
    always @(ss_cs[g*4 +: 4])
      if (&ss_cs[g*4 +: 4]) sclk_last_cycle[g] = -1;
  end

  task automatic db_txn(input [1:0] kind, input [1:0] die, input [31:0] a, d,
                        input int unsigned grp = 0, input bit expect_timeout = 0);
    int unsigned done_before, error_before;
    @(negedge clk);
    done_before = s_done_count[grp];
    error_before = s_error_count[grp];
    hwo.spi_cmd_kind[grp] = kind;
    hwo.spi_cmd_die[grp] = die;
    hwo.spi_addr[grp] = a;
    hwo.spi_wdata[grp] = d;
    @(negedge clk); hwo.spi_db_go[grp] = 1'b1;
    @(negedge clk); hwo.spi_db_go[grp] = 1'b0;
    @(negedge clk);
    while (s_busy[grp]) @(negedge clk);
    repeat (2) @(negedge clk);
    chk(s_done_count[grp] == done_before + (expect_timeout ? 0 : 1),
        $sformatf("%s group %0d completion count", cur_test, grp));
    chk(s_error_count[grp] == error_before + (expect_timeout ? 1 : 0),
        $sformatf("%s group %0d timeout count", cur_test, grp));
  endtask

  // APB 窗体访问(等待周期直至 pready)
  task automatic win_wr(input [11:0] a, input [31:0] d, output bit slverr);
    @(posedge clk); wp_sel <= 1; wp_en <= 0; wp_wr <= 1; wp_addr <= a; wp_wdata <= d;
    @(posedge clk); wp_en <= 1;
    @(posedge clk);
    while (!wp_rdy) @(posedge clk);
    slverr = wp_slv;
    wp_sel <= 0; wp_en <= 0;
    @(posedge clk);
  endtask
  task automatic win_rd(input [11:0] a, output [31:0] d, output bit slverr);
    @(posedge clk); wp_sel <= 1; wp_en <= 0; wp_wr <= 0; wp_addr <= a;
    @(posedge clk); wp_en <= 1;
    @(posedge clk);
    while (!wp_rdy) @(posedge clk);
    d = wp_rdata; slverr = wp_slv;
    wp_sel <= 0; wp_en <= 0;
    @(posedge clk);
  endtask

  // ==========================================================================
  // B. 裸引擎(WR16/RD16/看门狗/时序测量;第三份芯片从机)
  // ==========================================================================
  logic        b_cmd_valid, b_cmd_ready;
  logic [4:0]  b_die;
  logic [1:0]  b_kind;
  logic [31:0] b_addr;
  logic        b_wv, b_wr_;
  logic [31:0] b_wd;
  logic        b_rv, b_rr;
  logic [31:0] b_rd;
  logic        b_done, b_err;
  logic [7:0]  b_clkdiv;
  logic [31:0] b_tmo;
  logic        b_sclk, b_mosi;
  logic [3:0]  b_cs, b_miso;

  tj_spi_engine #(.GRP(0)) u_beng (
    .clk(clk), .rst_n(rst_n),
    .cfg_clkdiv(b_clkdiv), .cfg_tmo(b_tmo),
    .cmd_valid(b_cmd_valid), .cmd_ready(b_cmd_ready),
    .die_id(b_die), .cmd_kind(b_kind), .addr(b_addr),
    .wdat_valid(b_wv), .wdat_ready(b_wr_), .wdat(b_wd),
    .rdat_valid(b_rv), .rdat_ready(b_rr), .rdat(b_rd),
    .done(b_done), .err_timeout(b_err),
    .sclk(b_sclk), .mosi(b_mosi), .cs_n(b_cs), .miso(b_miso)
  );

  logic [31:0] h2_haddr, h2_hwdata, h2_hrdata;
  logic [2:0]  h2_hburst, h2_hsize;
  logic [1:0]  h2_htrans;
  logic        h2_hwrite, h2_hready, h2_hresp, h2_lock;
  logic [3:0]  h2_hprot;
  logic        miso2;
  spi2ahb u_chip2 (
    .spi_cs_n(b_cs[0]), .spi_sck(b_sclk), .spi_mosi(b_mosi), .spi_miso(miso2),
    .hclk(clk), .hresetn(rst_n),
    .hrdata(h2_hrdata), .hready(h2_hready), .hresp(h2_hresp),
    .haddr(h2_haddr), .hburst(h2_hburst), .hmastlock(h2_lock), .hprot(h2_hprot),
    .hsize(h2_hsize), .htrans(h2_htrans), .hwdata(h2_hwdata), .hwrite(h2_hwrite)
  );
  ahb_ram_beh u_ram2 (
    .hclk(clk), .hresetn(rst_n),
    .haddr(h2_haddr), .hburst(h2_hburst), .hsize(h2_hsize), .htrans(h2_htrans),
    .hwdata(h2_hwdata), .hwrite(h2_hwrite),
    .hrdata(h2_hrdata), .hready(h2_hready), .hresp(h2_hresp)
  );
  assign b_miso = {3'b000, miso2};

  // ---- 裸引擎时序测量(T5/T6):CS/沿关系 ----
  realtime t_cs_fall, t_edge_last, t_cs_rise;
  realtime min_setup = 1e9, min_hold = 1e9, min_gap = 1e9;
  realtime sclk_rise_prev = -1, min_period = 1e9;
  int unsigned frame_edges;
  int unsigned frame_edges_q[$];
  bit first_edge_seen;

  always @(negedge b_cs[0]) if (rst_n) begin
    t_cs_fall = $realtime;
    if (t_cs_rise > 0 && ($realtime - t_cs_rise) < min_gap)
      min_gap = $realtime - t_cs_rise;
    frame_edges = 0;
    first_edge_seen = 0;
  end
  always @(posedge b_sclk) if (!b_cs[0]) begin
    if (!first_edge_seen) begin
      first_edge_seen = 1;
      if (($realtime - t_cs_fall) < min_setup) min_setup = $realtime - t_cs_fall;
    end
    if (sclk_rise_prev > 0 && ($realtime - sclk_rise_prev) < min_period)
      min_period = $realtime - sclk_rise_prev;
    sclk_rise_prev = $realtime;
    frame_edges++;
  end
  always @(b_sclk) if (!b_cs[0]) t_edge_last = $realtime;
  always @(posedge b_cs[0]) if (rst_n) begin
    t_cs_rise = $realtime;
    if (($realtime - t_edge_last) < min_hold) begin
      min_hold = $realtime - t_edge_last;
      if (min_hold < 50.0)
        $display("DBG hold=%.1f cs_rise@%0t edge_last=%0t", min_hold, $time, t_edge_last);
    end
    frame_edges_q.push_back(frame_edges);
    sclk_rise_prev = -1;   // 周期测量不跨帧
  end

  // Count transactions at the public engine interface.
  int unsigned b_cmd_count = 0, b_write_count = 0, b_read_count = 0;
  int unsigned b_done_count = 0, b_error_count = 0;
  logic [31:0] b_last_read;
  always @(posedge clk) if (rst_n) begin
    if (b_cmd_valid && b_cmd_ready) b_cmd_count++;
    if (b_wv && b_wr_) b_write_count++;
    if (b_rv && b_rr) begin
      b_read_count++;
      b_last_read = b_rd;
    end
    if (b_done) b_done_count++;
    if (b_err) b_error_count++;
  end

  // 裸引擎 done/err 粘滞采样(done 为单拍脉冲,TB 侧任意长延迟都不允许错过)
  bit b_done_seen, b_err_seen;
  always @(posedge clk) begin
    if (b_done) b_done_seen = 1;
    if (b_err)  b_err_seen  = 1;
  end

  // 裸引擎事务任务
  task automatic beng_cmd(input [1:0] kind, input [31:0] a);
    @(posedge clk);
    b_done_seen = 0; b_err_seen = 0;
    b_kind <= kind; b_die <= 5'd0; b_addr <= a; b_cmd_valid <= 1'b1;
    @(posedge clk);
    while (!b_cmd_ready) @(posedge clk);       // 等引擎回到 IDLE(ready=1)
    do @(posedge clk); while (b_cmd_ready);    // ready 回落 = 命令已被采纳
    b_cmd_valid <= 1'b0;
  endtask

  // ==========================================================================
  // 主序列
  // ==========================================================================
  logic [31:0] exp0 [0:255];
  logic [31:0] snap1 [0:255];
  logic [31:0] got, d16 [0:15];
  bit serr;
  int unsigned pre_edges, sw_errors_before;
  int k;

  initial begin
    tj_cases_init("T1,T2,T3,T4,T5,T6,T7,T8,T9,T10,T11,T12,T13,T14");
    hwo = '0;
    for (int g = 0; g < 8; g++) begin
      hwo.spi_clkdiv[g] = 8'd1;            // 25MHz
      hwo.spi_tmo[g]    = 32'd0;           // 子系统不开看门狗
    end
    hwo.spiwin_ctrl_en = 1'b0;
    wp_sel = 0; wp_en = 0; wp_wr = 0; wp_addr = '0; wp_wdata = '0;
    b_cmd_valid = 0; b_die = '0; b_kind = '0; b_addr = '0;
    b_wv = 0; b_wd = '0; b_rr = 1;
    b_clkdiv = 8'd1; b_tmo = 32'd0;

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    // ---------- T1 门铃 WR1 ×16 + 共享总线免扰 ----------
    if (tj_run_case("T1")) begin
      cur_test = "T1";
      foreach (snap1[i]) snap1[i] = u_ram1.mem[i];
      for (k = 0; k < 16; k++) begin
        exp0[k] = $urandom;
        db_txn(2'd0, 2'd0, 32'(k*4), exp0[k]);
      end
      for (k = 0; k < 16; k++)
        chk(u_ram0.mem[k] === exp0[k], $sformatf("T1 WR1 ram0[%0d]", k));
      for (k = 0; k < 256; k++)
        chk(u_ram1.mem[k] === snap1[k], $sformatf("T1 免扰 ram1[%0d]", k));
    end

    // ---------- T2 门铃 RD1 ×16 ----------
    if (tj_run_case("T2")) begin
      cur_test = "T2";
      for (k = 0; k < 16; k++) begin
        u_ram0.mem[512+k] = $urandom;
        db_txn(2'd1, 2'd0, 32'((512+k)*4), 32'h0);
        chk(s_rdata[0] === u_ram0.mem[512+k], $sformatf("T2 RD1 [%0d]", k));
      end

      // ---------- T2b 门铃到 die1(cs_n[1] 通路) ----------
      cur_test = "T2b";
      db_txn(2'd0, 2'd1, 32'h40, 32'hD1E1_BEEF);
      chk(u_ram1.mem['h10] === 32'hD1E1_BEEF, "T2b die1 WR1");
    end

    // ---------- T3 裸引擎 WR16(长随机断供,保证真实触发帧中 sclk 停顿) ----------
    if (tj_run_case("T3")) begin
      cur_test = "T3";
      // 一个字 32bit@25MHz = 128 pclk;断供上限 300 拍 > 128,必然多次把引擎逼进停等
      beng_cmd(2'd1, 32'h0000_0100);         // ram2[64..79]
      for (k = 0; k < 16; k++) begin
        exp0[k] = $urandom;
        repeat ($urandom_range(0, 300)) @(posedge clk);
        @(posedge clk); b_wv <= 1'b1; b_wd <= exp0[k];
        @(posedge clk);
        while (!b_wr_) @(posedge clk);
        b_wv <= 1'b0;
      end
      @(posedge clk);
      while (!b_done_seen && !b_err_seen) @(posedge clk);
      chk(!b_err_seen, "T3 无超时");
      repeat (120) @(posedge clk);           // 芯片 AHB 排空(闭合最坏 16×3+同步 ≈55 拍,审查修正)
      for (k = 0; k < 16; k++)
        chk(u_ram2.mem[64+k] === exp0[k], $sformatf("T3 WR16 ram2[%0d]", 64+k));
      chk(frame_edges_q[$] === 552, $sformatf("T3 WR16 帧沿数 %0d(应 552)", frame_edges_q[$]));
    end

    // ---------- T4 裸引擎 RD16(长随机反压,真实触发 skid 满→sclk 停顿) ----------
    if (tj_run_case("T4")) begin
      cur_test = "T4";
      for (k = 0; k < 16; k++) u_ram2.mem[128+k] = $urandom;
      b_rr = 1'b0;
      beng_cmd(2'd3, 32'h0000_0200);
      for (k = 0; k < 16; k++) begin
        // 无竞态取数模式:rr 压低等 rv 驻留 → 读数 → 单拍消费
        t4_k = k;
        repeat ($urandom_range(0, 300)) @(posedge clk);
        @(posedge clk);
        while (!b_rv) @(posedge clk);
        d16[k] = b_rd;
        b_rr <= 1'b1;
        @(posedge clk);
        b_rr <= 1'b0;
      end
      @(posedge clk);
      while (!b_done_seen && !b_err_seen) @(posedge clk);
      chk(!b_err_seen, "T4 无超时");
      for (k = 0; k < 16; k++)
        chk(d16[k] === u_ram2.mem[128+k], $sformatf("T4 RD16 [%0d]", k));

      // ---------- T4b RD16 定向最坏等待(审查复现的静默全 0 缺陷回归) ----------
      cur_test = "T4b";
      // WS=2 曾使芯片读突发拖过 phase B cmd 覆盖点 → 16 字全 0 且零错误;
      // 修复=块请求后排空间隔 1µs(SPI_BLKDRAIN_GAP_CYC),WS=3/5 都必须正确
      for (int ws = 2; ws <= 5; ws += 1) begin
        u_ram2.force_ws = ws;
        for (k = 0; k < 16; k++) u_ram2.mem[160+k] = $urandom + ws;
        beng_cmd(2'd3, 32'h0000_0280);
        for (k = 0; k < 16; k++) begin
          @(posedge clk);
          while (!b_rv) @(posedge clk);
          d16[k] = b_rd;
          b_rr <= 1'b1;
          @(posedge clk);
          b_rr <= 1'b0;
        end
        @(posedge clk);
        while (!b_done_seen && !b_err_seen) @(posedge clk);
        chk(!b_err_seen, $sformatf("T4b ws=%0d 无超时", ws));
        for (k = 0; k < 16; k++)
          chk(d16[k] === u_ram2.mem[160+k], $sformatf("T4b ws=%0d RD16[%0d]", ws, k));
      end
      u_ram2.force_ws = -1;
      b_rr = 1'b1;                            // 恢复默认即时消费(T6 等依赖)
    end

    // ---------- T5 时序断言(此前全部帧的实测最小值) ----------
    if (tj_run_case("T5")) begin
      if (tj_case_filter_active) begin
        // Generate two frames so every timing minimum has an observation.
        for (int n = 0; n < 2; n++) begin
          beng_cmd(2'd0, 32'h800 + 32'(n*4));
          @(posedge clk); b_wv <= 1; b_wd <= 32'h1234_0000 + 32'(n);
          @(posedge clk); while (!b_wr_) @(posedge clk);
          b_wv <= 0;
          @(posedge clk); while (!b_done_seen) @(posedge clk);
        end
      end
      cur_test = "T5";
      chk(min_setup >= 20.0, $sformatf("T5 CS setup %.1fns ≥20", min_setup));
      chk(min_hold  >= 50.0, $sformatf("T5 CS hold %.1fns ≥50", min_hold));
      chk(min_gap   >= 40.0, $sformatf("T5 CS gap %.1fns ≥40", min_gap));
      chk(min_period >= 40.0, $sformatf("T5 sclk 周期 %.1fns(≤25MHz)", min_period));
    end

    // ---------- T6 CLKDIV=0 钳位 ----------
    if (tj_run_case("T6")) begin
      cur_test = "T6";
      min_period = 1e9;
      b_clkdiv = 8'd0;
      u_ram2.mem[300] = 32'hC1A3_0000;
      beng_cmd(2'd2, 32'(300*4));
      @(posedge clk);
      while (!b_done_seen) @(posedge clk);
      chk(b_rd === 32'hC1A3_0000, "T6 RD1 数据");  // skid_q 完成后保持
      chk(min_period >= 40.0, $sformatf("T6 钳位后周期 %.1fns", min_period));
      b_clkdiv = 8'd1;
    end

    // ---------- T7 看门狗:WR16 断供 → 超时中止 → 自恢复 ----------
    if (tj_run_case("T7")) begin
      cur_test = "T7";
      b_tmo = 32'd4000;
      beng_cmd(2'd1, 32'h0000_0400);
      for (k = 0; k < 4; k++) begin
        @(posedge clk); b_wv <= 1'b1; b_wd <= 32'hBAD0 + k;
        @(posedge clk);
        while (!b_wr_) @(posedge clk);
        b_wv <= 1'b0;
      end                                     // 断供,等看门狗
      @(posedge clk);
      while (!b_err_seen) @(posedge clk);
      chk(b_cs === 4'hF, "T7 中止后 CS 全高");
      b_tmo = 32'd0;
      repeat (50) @(posedge clk);
      u_ram2.mem[400] = 32'h0;
      beng_cmd(2'd0, 32'(400*4));
      @(posedge clk); b_wv <= 1'b1; b_wd <= 32'hA11A_C0DE;
      @(posedge clk);
      while (!b_wr_) @(posedge clk);
      b_wv <= 1'b0;
      @(posedge clk);
      while (!b_done_seen) @(posedge clk);
      repeat (20) @(posedge clk);
      chk(u_ram2.mem[400] === 32'hA11A_C0DE, "T7 中止后 WR1 自恢复");
    end

    // ---------- T8 SPIWIN:EN 门控 + 窗体写读 ----------
    if (tj_run_case("T8")) begin
      cur_test = "T8";
  `ifdef SPI_TB_DBG
      $display("DBG T8 start @%0t", $time);
  `endif
      win_wr(12'h010, 32'h1234_5678, serr);
      chk(serr === 1'b1, "T8 EN=0 → pslverr");
      hwo.spiwin_ctrl_en  = 1'b1;
      hwo.spiwin_page_die = 5'd0;             // die0(组0)
      hwo.spiwin_offs     = 20'h00000;        // 芯片地址 = 窗内偏移
      win_wr(12'h300, 32'h57A9_0300, serr);
      chk(serr === 1'b0, "T8 窗写无错");
      chk(u_ram0.mem['hC0] === 32'h57A9_0300, "T8 窗写 ram0[0xC0]");
      u_ram0.mem['hC4>>2] = 32'hFEED_C0DE;
      win_rd(12'h0C4, got, serr);
      chk(serr === 1'b0 && got === 32'hFEED_C0DE, "T8 窗读");
      // 页偏移:OFFS=0x00001 → 芯片地址 = 0x1000+偏移
      hwo.spiwin_offs = 20'h00001;
      win_wr(12'h020, 32'h0FF5_E7AA, serr);
      chk(u_ram0.mem[(32'h1020)>>2] === 32'h0FF5_E7AA, "T8 OFFS 页偏移");
      hwo.spiwin_offs = 20'h00000;
    end

    // ---------- T9 门铃+窗口同时敲(同组,仲裁串行化) ----------
    if (tj_run_case("T9")) begin
      if (tj_case_filter_active) begin
        hwo.spiwin_ctrl_en = 1;
        hwo.spiwin_page_die = 0;
        hwo.spiwin_offs = 0;
      end
      cur_test = "T9";
      fork
        begin
          db_txn(2'd0, 2'd0, 32'(700*4), 32'hDB00_0001);
        end
        begin
          win_wr(12'(704*4), 32'hA0A0_0002, serr);
        end
      join
      repeat (10) @(posedge clk);
      chk(u_ram0.mem[700] === 32'hDB00_0001, "T9 门铃笔");
      chk(u_ram0.mem[704] === 32'hA0A0_0002, "T9 窗口笔");
      chk(serr === 1'b0, "T9 窗口无错");
    end

    // T10: Group 7 doorbell access, checking each completion separately.
    if (tj_run_case("T10")) begin
      cur_test = "T10";
      db_txn(2'd0, 2'd3, 32'h88, 32'hD1E3_1CAF, 7);
      chk(u_ram3.mem['h22] === 32'hD1E3_1CAF, "T10 group7/die31 WR1");
      u_ram3.mem['h30] = 32'h7A5C_0FEE;
      db_txn(2'd1, 2'd3, 32'hC0, 32'h0, 7);
      chk(s_rdata[7] === 32'h7A5C_0FEE, "T10 group7/die31 RD1");
    end

    // ---------- T11 SPIWIN 超时路径(TMO < 事务时长 → 中止、当笔 pslverr、ERR 事件) ----------
    if (tj_run_case("T11")) begin
      if (tj_case_filter_active) begin
        hwo.spiwin_ctrl_en = 1;
        hwo.spiwin_page_die = 0;
        hwo.spiwin_offs = 0;
      end
      cur_test = "T11";
      sw_errors_before = sw_error_count;
      hwo.spi_tmo[0] = 32'd200;              // WR1 全程 ≈3µs ≫ 2µs 看门狗
      win_wr(12'h500, 32'hDEAD_0011, serr);
      chk(serr === 1'b1, "T11 窗写超时 pslverr");
      chk(sw_error_count == sw_errors_before+1, "T11 one SPIWIN timeout event");
      hwo.spi_tmo[0] = 32'd0;
      repeat (50) @(posedge clk);
      win_wr(12'h504, 32'hC001_0BAD, serr);
      chk(serr === 1'b0 && u_ram0.mem[('h504)>>2] === 32'hC001_0BAD, "T11 超时后窗口自恢复");
      chk(sw_error_count == sw_errors_before+1, "T11 recovery has no extra timeout");
    end

    // T12: retain a read result, queue a write, then release the read backpressure.
    if (tj_run_case("T12")) begin
      begin : t12_command_ready
        int cmd_before, writes_before, reads_before, done_before, errors_before, frames_before;
        bit held_read_ok, pins_idle;
        cur_test = "T12";
        @(negedge clk);
        b_clkdiv = 8'd1;
        b_tmo = 0;
        b_rr = 1;
        beng_cmd(2'd0, 32'h0000_0600);
        @(negedge clk); b_wv = 1; b_wd = 32'hA55A_55AA;
        do @(posedge clk); while (!b_wr_);
        @(negedge clk); b_wv = 0;
        while (!b_done_seen && !b_err_seen) @(negedge clk);
        chk(b_done_seen && !b_err_seen, "T12 seed write completes");

        @(negedge clk); b_rr = 0;
        beng_cmd(2'd2, 32'h0000_0600);
        while (!b_done_seen && !b_err_seen) @(negedge clk);
        @(negedge clk);
        chk(b_done_seen && !b_err_seen && b_rv && b_rd === 32'hA55A_55AA,
            "T12 completed read remains available");
        chk(!b_cmd_ready, "T12 unread result blocks command ready");
        cmd_before = b_cmd_count;
        writes_before = b_write_count;
        reads_before = b_read_count;
        done_before = b_done_count;
        errors_before = b_error_count;
        frames_before = frame_edges_q.size();
        held_read_ok = 1;
        pins_idle = 1;
        b_kind = 0; b_die = 0; b_addr = 32'h0000_0604; b_cmd_valid = 1;
        b_wv = 1; b_wd = 32'hBEEF_1234;
        repeat (3000) begin
          @(negedge clk);
          held_read_ok &= (b_rv === 1'b1 && b_rd === 32'hA55A_55AA && b_cmd_ready === 1'b0);
          pins_idle &= (b_cs === 4'hF && b_sclk === 1'b0);
        end
        chk(held_read_ok, "T12 held result stays valid and unchanged");
        chk(b_cmd_count == cmd_before, "T12 no command accepted before read consumption");
        chk(pins_idle && frame_edges_q.size() == frames_before,
            "T12 no SPI frame before command handshake");
        chk(b_write_count == writes_before, "T12 no write data consumed before command handshake");
        chk(b_done_count == done_before && b_error_count == errors_before,
            "T12 no terminal event before command handshake");

        b_rr = 1;
        do @(posedge clk); while (!b_cmd_ready);
        @(negedge clk);
        b_cmd_valid = 0;
        b_done_seen = 0; b_err_seen = 0;
        chk(b_read_count == reads_before+1 && b_last_read === 32'hA55A_55AA,
            "T12 original read result delivered once");
        chk(b_cmd_count == cmd_before+1, "T12 queued command accepted once");
        do @(posedge clk); while (!b_wr_);
        @(negedge clk); b_wv = 0;
        while (!b_done_seen && !b_err_seen) @(negedge clk);
        @(negedge clk);
        chk(b_write_count == writes_before+1, "T12 write data consumed once");
        chk(b_done_count == done_before+1 && b_error_count == errors_before,
            "T12 queued write completes once without error");
        chk(frame_edges_q.size() == frames_before+1, "T12 queued write emits exactly one frame");
        beng_cmd(2'd2, 32'h0000_0604);
        while (!b_done_seen && !b_err_seen) @(negedge clk);
        @(negedge clk);
        chk(!b_err_seen && b_read_count == reads_before+2 && b_last_read === 32'hBEEF_1234,
            "T12 queued write readback matches");
      end
    end

    // T13: Use the doorbell as an independent path for SPIWIN die selection.
    if (tj_run_case("T13")) begin
      if (tj_case_filter_active) begin
        hwo.spiwin_ctrl_en = 1;
        hwo.spiwin_page_die = 0;
        hwo.spiwin_offs = 0;
      end
      cur_test = "T13";
      @(negedge clk);
      hwo.spiwin_page_die = 5'd31;
      hwo.spiwin_offs = 0;
      db_txn(2'd0, 2'd3, 32'h120, 32'hD131_FACE, 7);
      win_rd(12'h120, got, serr);
      chk(!serr && got === 32'hD131_FACE, "T13 doorbell write / SPIWIN read die31");
      win_wr(12'h124, 32'h5731_CAFE, serr);
      chk(!serr, "T13 SPIWIN write succeeds");
      db_txn(2'd1, 2'd3, 32'h124, 32'h0, 7);
      chk(s_rdata[7] === 32'h5731_CAFE, "T13 SPIWIN write / doorbell read die31");
      @(negedge clk); hwo.spiwin_page_die = 0;
    end

    // T14: Distinct group settings must reach distinct engines.
    if (tj_run_case("T14")) begin
      cur_test = "T14";
      @(negedge clk);
      hwo.spi_clkdiv[0] = 8'd1;
      hwo.spi_clkdiv[7] = 8'd4;
      sclk_min_cycles[0] = 32'h7FFF_FFFF;
      sclk_min_cycles[7] = 32'h7FFF_FFFF;
      sclk_last_cycle[0] = -1;
      sclk_last_cycle[7] = -1;
      fork
        db_txn(2'd0, 2'd0, 32'h700, 32'hD100_0000, 0);
        db_txn(2'd0, 2'd3, 32'h700, 32'hD700_0007, 7);
      join
      chk(sclk_min_cycles[0] == 4, "T14 group0 SCLK period is 4 clk cycles");
      chk(sclk_min_cycles[7] == 10, "T14 group7 SCLK period is 10 clk cycles");
      chk(u_ram0.mem['h700>>2] === 32'hD100_0000, "T14 group0 write completes");
      chk(u_ram3.mem['h700>>2] === 32'hD700_0007, "T14 group7 write completes");
      @(negedge clk);
      hwo.spi_tmo[0] = 32'd100000;
      hwo.spi_tmo[7] = 32'd40;
      fork
        db_txn(2'd0, 2'd0, 32'h704, 32'hD100_0001, 0);
        db_txn(2'd0, 2'd3, 32'h704, 32'hD700_0008, 7, 1'b1);
      join
      chk(u_ram0.mem['h704>>2] === 32'hD100_0001, "T14 group0 succeeds during group7 timeout");
      @(negedge clk);
      hwo.spi_clkdiv[7] = 8'd1;
      hwo.spi_tmo[0] = 0;
      hwo.spi_tmo[7] = 0;
    end

    if (errs == 0) $display("SPI TB PASS (%0d checks)", checks);
    else           $display("SPI TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end

  initial begin
    #50ms;
    $display("SPI TB TIMEOUT @ %s: word=%0d cs=%h sclk=%b cmd=%b/%b wr=%b/%b rd=%b/%b",
             cur_test, t4_k, b_cs, b_sclk, b_cmd_valid, b_cmd_ready,
             b_wv, b_wr_, b_rv, b_rr);
    $finish;
  end

`ifdef SPI_TB_DBG
  always @(posedge clk) if (b_rv && b_rr) $display("DBG consume k=%0d @%0t", t4_k, $time);
  always @(posedge b_rv) $display("DBG rv-rise k=%0d @%0t", t4_k, $time);
`endif

`ifdef SPI_TB_DBG
  always @(posedge clk) if (b_cmd_valid && b_cmd_ready)
    $display("DBG engine cmd kind=%0d addr=%08x die=%0d @%0t",
             b_kind, b_addr, b_die, $time);
  always @(posedge clk) if (wp_sel && wp_en && wp_rdy)
    $display("DBG window APB write=%b addr=%03x data=%08x error=%b @%0t",
             wp_wr, wp_addr, wp_wr ? wp_wdata : wp_rdata, wp_slv, $time);
  always @(posedge clk) if ((|s_done) || (|s_err))
    $display("DBG doorbell busy=%h done=%h error=%h @%0t", s_busy, s_done, s_err, $time);
`endif

endmodule
