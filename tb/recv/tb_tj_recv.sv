// File        : tb_tj_recv.sv
// Module      : tb_tj_recv
// Description : Check receive rings through APB, AXI and LVDS ports.
// Requires tj_ctrl_top; clock half-periods are configurable through plusargs.
`timescale 1ns/1ps
module tb_tj_recv;
  real pclk_hp = 5.0, maxi_hp = 1.2;
  initial begin
    void'($value$plusargs("TJ_PCLK_HP=%f", pclk_hp));
    void'($value$plusargs("TJ_MAXI_HP=%f", maxi_hp));
    if (pclk_hp <= 0 || maxi_hp <= 0) $fatal(1, "Clock half-periods must be positive");
    $display("RECV clocks: pclk_hp=%0f maxi_hp=%0f ns", pclk_hp, maxi_hp);
  end
  logic pclk = 0, presetn = 0, maxi_clk = 0, maxi_rstn = 0;
  always #(pclk_hp) pclk = ~pclk;
  always #(maxi_hp) maxi_clk = ~maxi_clk;

  int unsigned errs = 0, checks = 0;
  task automatic chk(input bit c, input string m);
    checks++;
    if (!c) begin
      errs++;
      if (errs <= 20) $display("FAIL: %s @%0t", m, $time);
    end
  endtask

  // CSR addresses.
  localparam [15:0] A_GLB_CTRL = 16'h000C;
  localparam [15:0] A_IRQ_RAW  = 16'h0100;
  localparam [15:0] A_TS_CTRL  = 16'h0208;
  localparam [15:0] A_S_SRCLO  = 16'h0C00;
  localparam [15:0] A_S_SRCHI  = 16'h0C04;
  localparam [15:0] A_S_CNT    = 16'h0C08;
  localparam [15:0] A_S_DB     = 16'h0C0C;
  localparam [15:0] A_S_STA    = 16'h0C10;
  localparam [15:0] A_LNK_EN   = 16'h2000;
  function automatic [15:0] A_RV(input int c, input [7:0] off);
    return 16'h1000 + 16'(c) * 16'h40 + 16'(off);
  endfunction

  // Controller instance.
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
  logic        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
  logic [3:0]  awid, bid;
  logic [47:0] awaddr;
  logic [7:0]  awlen;
  logic [2:0]  awsize;
  logic [1:0]  awburst, bresp;
  logic [127:0] wdata;
  logic [15:0]  wstrb;
  logic [NP-1:0]        lv_tx_tvalid, lv_tx_tready;
  logic [NP-1:0][95:0]  lv_tx_tdata;
  logic [NP-1:0]        lv_rx_tvalid, lv_rx_tready;
  logic [NP-1:0][95:0]  lv_rx_tdata;
  logic [3:0]  irq;

  tj_ctrl_top u_dut (
    .pclk, .presetn, .maxi_clk, .maxi_rstn,
    .psel, .penable, .pwrite, .paddr, .pwdata, .pready, .pslverr, .prdata,
    .awvalid, .awready, .awid, .awaddr, .awuser(), .awlen, .awsize, .awburst,
    .wvalid, .wready, .wdata, .wstrb, .wlast,
    .bvalid, .bready, .bresp, .bid,
    .arvalid, .arready, .arid, .araddr, .aruser(), .arlen, .arsize, .arburst,
    .rvalid, .rready, .rdata, .rresp, .rlast, .rid,
    .s_axis_pk_tvalid(1'b0), .s_axis_pk_tready(), .s_axis_pk_tdata('0),
    .s_axis_pk_tlast(1'b0),
    .m_axis_pk_tvalid(), .m_axis_pk_tready(1'b1), .m_axis_pk_tdata(), .m_axis_pk_tlast(),
    .irq,
    .lv_tx_tvalid, .lv_tx_tready, .lv_tx_tdata,
    .lv_rx_tvalid, .lv_rx_tready, .lv_rx_tdata,
    .lvcfg_din(), .lvcfg_din_vld(), .lvcfg_dout('0), .lvcfg_dout_vld('0),
    .spi_sclk(), .spi_mosi(), .spi_cs_n(), .spi_miso('0),
    .chip_rst_n(), .clkctl(), .uart_rx(1'b1), .uart_tx()
  );

  // DDR model; address bit 40 selects an error response.

  logic [127:0] ddr [longint unsigned];
  longint unsigned ring_base [3];
  int unsigned ring_size [3];

  // AXI read model for SEND loopback.
  typedef struct { logic [47:0] addr; logic [7:0] len; logic [3:0] id; } ar_t;
  ar_t arq[$];
  int ar_stall;
  always @(posedge maxi_clk) ar_stall <= $urandom_range(0, 9);
  assign arready = maxi_rstn && (ar_stall != 0);
  always @(posedge maxi_clk) if (arvalid && arready) begin
    ar_t a;
    chk(arsize == 3'd4 && arburst == 2'b01 && araddr[3:0] == 0,
        "AXI read uses aligned 16-byte INCR beats");
    a.addr = araddr; a.len = arlen; a.id = arid; arq.push_back(a);
  end
  initial begin
    rvalid = 0; rdata = '0; rresp = 2'b00; rlast = 0; rid = '0;
    wait (maxi_rstn);
    forever begin
      @(posedge maxi_clk);
      if (arq.size() > 0) begin
        automatic ar_t a = arq.pop_front();
        for (int b = 0; b <= a.len; b++) begin
          while ($urandom_range(0, 3) == 0) @(posedge maxi_clk);
          rvalid <= 1; rid <= a.id;
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

  // AXI write model.
  typedef struct { logic [47:0] addr; logic [3:0] id; } aw_t;
  aw_t awq[$];
  logic [127:0] wq[$];
  int aw_stall, w_stall;
  int unsigned wr_land_cnt;  // Successful write count.
  int unsigned wr_rsp_count[3];  // Completed AXI responses per ring, including errors.
  always @(posedge maxi_clk) begin
    aw_stall <= $urandom_range(0, 9);
    w_stall  <= $urandom_range(0, 9);
  end
  assign awready = maxi_rstn && (aw_stall != 0);
  assign wready  = maxi_rstn && (w_stall != 0);
  always @(posedge maxi_clk) begin
    if (awvalid && awready) begin
      aw_t a;
      chk(awlen == 0 && awsize == 3'd4 && awburst == 2'b01 && awaddr[3:0] == 0,
          "AXI write uses one aligned 16-byte beat");
      a.addr = awaddr; a.id = awid; awq.push_back(a);
    end
    if (wvalid && wready) begin
      chk(wstrb == 16'hFFFF && wlast, "AXI write includes all 16 bytes and WLAST");
      wq.push_back(wdata);
    end
  end
  initial begin
    bvalid = 0; bresp = 2'b00; bid = '0;
    wait (maxi_rstn);
    forever begin
      @(posedge maxi_clk);
      if (awq.size() > 0 && wq.size() > 0) begin
        automatic aw_t a = awq.pop_front();
        automatic logic [127:0] d = wq.pop_front();
        repeat ($urandom_range(1, 8)) @(posedge maxi_clk);  // Delay the B response.
        if (!a.addr[40]) begin
          ddr[a.addr >> 4] = d;
          wr_land_cnt++;
        end
        bvalid <= 1; bresp <= a.addr[40] ? 2'b10 : 2'b00; bid <= a.id;
        @(posedge maxi_clk);
        while (!bready) @(posedge maxi_clk);
        begin
          int ring;
          ring = -1;
          for (int c = 0; c < 3; c++)
            if (a.addr >= ring_base[c] && a.addr < ring_base[c] + 16*ring_size[c]) ring = c;
          chk(ring >= 0, "AXI write addresses a configured receive ring");
          if (ring >= 0) wr_rsp_count[ring]++;
        end
        bvalid <= 0;
      end
    end
  end

  // Select external stimulus or SEND-to-RECV loopback.

  bit loop_en;
  logic [NP-1:0]       drv_v;
  logic [NP-1:0][95:0] drv_d;
  assign lv_rx_tvalid = loop_en ? lv_tx_tvalid : drv_v;
  assign lv_rx_tdata  = loop_en ? lv_tx_tdata  : drv_d;
  assign lv_tx_tready = loop_en ? lv_rx_tready : {NP{1'b1}};

  task automatic send_rx(input int p, input logic [95:0] d);
    @(posedge maxi_clk);
    drv_d[p] <= d; drv_v[p] <= 1'b1;
    @(posedge maxi_clk);
    while (!lv_rx_tready[p]) @(posedge maxi_clk);
    drv_v[p] <= 1'b0;
    repeat ($urandom_range(0, 2)) @(posedge maxi_clk);
  endtask

  // Host APB transactions.

  task automatic apb_wr(input [15:0] a, input [31:0] d);
    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 1; paddr <= a; pwdata <= d;
    @(posedge pclk); penable <= 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    chk(!pslverr, $sformatf("APB write %04x returned PSLVERR", a));
    psel <= 0; penable <= 0; @(posedge pclk);
  endtask
  task automatic apb_rd(input [15:0] a, output [31:0] d);
    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 0; paddr <= a;
    @(posedge pclk); penable <= 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    d = prdata;
    chk(!pslverr, $sformatf("APB read %04x returned PSLVERR", a));
    psel <= 0; penable <= 0; @(posedge pclk);
  endtask

  // Ring configuration and reference records.

  int unsigned     rptr_sh   [3];  // Cumulative host read pointers.
  logic [15:0]     last_tag  [3];
  bit              tag_seen  [3];

  typedef struct { bit is_end; logic [95:0] pkt; } gold_t;
  gold_t exp_q [3][$];

  function automatic logic [127:0] rd_ring(input int c, input int unsigned idx);
    return ddr[(ring_base[c] >> 4) + (idx & (ring_size[c] - 1))];
  endfunction

  // Read completed records, check content and timestamps, then update RPTR.
  task automatic consume(input int c, input int unsigned upto_min);
    logic [31:0] wp;
    logic [127:0] r;
    gold_t g;
    while (rptr_sh[c] < upto_min) begin
      apb_rd(A_RV(c, 8'h18), wp);
      if ($isunknown(wp) || wp < rptr_sh[c] || wp > wr_rsp_count[c])
        $fatal(1, "Invalid WPTR: ch=%0d WPTR=%0d RPTR=%0d AXI responses=%0d",
               c, wp, rptr_sh[c], wr_rsp_count[c]);
      while (rptr_sh[c] < wp) begin
        r = rd_ring(c, rptr_sh[c]);
        chk(exp_q[c].size() > 0, $sformatf("ch%0d unexpected record at index %0d", c, rptr_sh[c]));
        if (exp_q[c].size() > 0) begin
          g = exp_q[c].pop_front();
          chk(r[95:0] === g.pkt, $sformatf("ch%0d record %0d packet %h != %h", c, rptr_sh[c], r[95:0], g.pkt));
          chk(r[103:96] === 8'(c), $sformatf("ch%0d record %0d channel=%h", c, rptr_sh[c], r[103:96]));
          chk(r[111:104] === {7'h0, g.is_end}, $sformatf("ch%0d record %0d flags=%h", c, rptr_sh[c], r[111:104]));
          if (tag_seen[c])
            chk(r[127:112] >= last_tag[c], $sformatf("ch%0d record %0d timestamp moved backwards: %h < %h", c, rptr_sh[c], r[127:112], last_tag[c]));
          last_tag[c] = r[127:112]; tag_seen[c] = 1;
        end
        rptr_sh[c]++;
      end
      apb_wr(A_RV(c, 8'h1C), rptr_sh[c]);
    end
  endtask

  task automatic cfg_settle;
    repeat (8) @(posedge maxi_clk);
    repeat (4) @(posedge pclk);
  endtask

  task automatic events_settle;
    repeat (80) @(posedge maxi_clk);
    repeat (8) @(posedge pclk);
  endtask

  task automatic ring_cfg(input int c, input longint unsigned base,
                          input int unsigned size, input int unsigned wmark,
                          input bit pol, input bit ie_wmark, input bit ie_end);
    ring_base[c] = base; ring_size[c] = size;
    apb_wr(A_RV(c, 8'h10), 32'h0);  // Call only after prior writes have drained.
    cfg_settle();
    apb_wr(A_RV(c, 8'h00), base[31:0]);
    apb_wr(A_RV(c, 8'h04), {16'h0, base[47:32]});
    apb_wr(A_RV(c, 8'h08), size);
    apb_wr(A_RV(c, 8'h0C), wmark);
    cfg_settle();
    apb_wr(A_RV(c, 8'h10), {22'h0, ie_end, ie_wmark, 6'h0, pol, 1'b1});
    cfg_settle();
  endtask

  // Rotate packet types independently of DUT constants.
  localparam logic [3:0] CHIP_END_CODES  [4] = '{4'h6, 4'hE, 4'h4, 4'hC};
  localparam logic [3:0] CHIP_DATA_CODES [2] = '{4'h2, 4'hA};
  int end_rr = 0;
  int dat_rr = 0;

  function automatic logic [95:0] mk_pkt(input bit is_end);
    logic [95:0] p;
    p = {$urandom, $urandom, $urandom};
    if (is_end) begin
      p[3:0] = CHIP_END_CODES[end_rr % 4];
      end_rr++;
    end else begin
      p[3:0] = CHIP_DATA_CODES[dat_rr % 2];
      dat_rr++;
    end
    return p;
  endfunction

  // Send a record expected to reach an enabled, non-full ring.
  task automatic feed(input int c, input bit is_end);
    gold_t g;
    g.is_end = is_end; g.pkt = mk_pkt(is_end);
    exp_q[c].push_back(g);
    send_rx((c / 3) * 4 + (c % 3), g.pkt);
  endtask

  // Test sequence.

  logic [31:0] v, v2;
  logic [127:0] recs[$];
  int unsigned base_wp, loopback_writes;

  initial begin
    psel = 0; penable = 0; pwrite = 0; paddr = '0; pwdata = '0;
    drv_v = '0; drv_d = '0; loop_en = 0;
    foreach (rptr_sh[i]) begin rptr_sh[i] = 0; wr_rsp_count[i] = 0; tag_seen[i] = 0; end
    #200ns;
    presetn = 1; maxi_rstn = 1;
    #200ns;

    // P0: Initial configuration.
    apb_wr(A_TS_CTRL, 32'h0000_0003);  // Enable timestamps with prescale /16.
    ring_cfg(0, 64'h0000_2000_0000, 64, 8, 1'b0, 1'b1, 1'b1);
    ring_cfg(1, 64'h0000_2100_0000, 32, 8, 1'b0, 1'b1, 1'b1);
    // Disable channel 2 END interrupts for P3.
    ring_cfg(2, 64'h0000_2200_0000, 16, 4, 1'b0, 1'b1, 1'b0);
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);

    // P1: Three channels, ring wrap and unused-port discard.
    for (int n = 0; n < 12; n++)
      for (int c = 0; c < 3; c++) feed(c, 1'b0);
    send_rx(3, 96'hDEAD_0000_DEAD_0000_DEAD_0000);  // Unused port 3.
    consume(0, 12); consume(1, 12); consume(2, 12);
    // Let the RPTR snapshot release space before a new drop-mode burst.
    cfg_settle();
    // Wrap the 16-record channel 2 ring.
    for (int n = 0; n < 24; n++) begin
      feed(2, 1'b0);
      if (n % 8 == 7) consume(2, rptr_sh[2] + 8);
    end
    consume(2, 36);
    chk(exp_q[0].size() == 0 && exp_q[1].size() == 0 && exp_q[2].size() == 0,
        "P1: all expected records checked");
    $display("P1 done (%0d checks, %0d errs)", checks, errs);

    // P2: Watermark crossing and rearming.
    events_settle();
    apb_wr(A_RV(1, 8'h14), 32'h7);  // Clear sticky events.
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    for (int n = 0; n < 8; n++) feed(1, 1'b0);  // Reach the watermark of eight records.
    v = 0;
    for (int t = 0; t < 3000 && !v[0]; t++) apb_rd(A_RV(1, 8'h14), v);
    chk(v[0], "P2: WMARK_HIT");
    apb_rd(A_IRQ_RAW, v2);
    chk(v2[13], "P2: channel 1 watermark interrupt");
    apb_wr(A_RV(1, 8'h14), 32'h7);
    apb_rd(A_RV(1, 8'h14), v);
    chk(!v[0], "P2: W1C clears the watermark event");
    consume(1, rptr_sh[1] + 8);  // Drain the ring.
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    for (int n = 0; n < 8; n++) feed(1, 1'b0);  // Cross the watermark again.
    v = 0;
    for (int t = 0; t < 3000 && !v[0]; t++) apb_rd(A_RV(1, 8'h14), v);
    chk(v[0], "P2: watermark retriggers after consumption");
    apb_wr(A_RV(1, 8'h14), 32'h7);
    consume(1, rptr_sh[1] + 8);
    $display("P2 done (%0d checks, %0d errs)", checks, errs);

    // P3: END flags and interrupt enables.
    events_settle();
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    feed(0, 1'b1);  // Channel 0 END interrupt enabled.
    v = 0;
    for (int t = 0; t < 3000 && !v[1]; t++) apb_rd(A_RV(0, 8'h14), v);
    chk(v[1], "P3: ch0 ENDPKT");
    apb_rd(A_IRQ_RAW, v2);
    chk(v2[12], "P3: channel 0 END interrupt enabled");
    feed(2, 1'b1);  // Channel 2 END interrupt disabled.
    v = 0;
    for (int t = 0; t < 3000 && !v[1]; t++) apb_rd(A_RV(2, 8'h14), v);
    chk(v[1], "P3: channel 2 END status is independent of interrupt enable");
    apb_rd(A_IRQ_RAW, v2);
    chk(!v2[14], "P3: channel 2 END interrupt disabled");
    apb_wr(A_RV(0, 8'h14), 32'h7); apb_wr(A_RV(2, 8'h14), 32'h7);
    consume(0, rptr_sh[0] + 1); consume(2, rptr_sh[2] + 1);
    $display("P3 done (%0d checks, %0d errs)", checks, errs);

    // P4: Drop on overflow and preserve unread records.
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    for (int n = 0; n < 16; n++) feed(2, 1'b0);  // Fill the 16-record ring.
    // Wait for every write response before injecting overflow packets.
    v = 0;
    for (int t = 0; t < 3000 && v != rptr_sh[2] + 16; t++) apb_rd(A_RV(2, 8'h18), v);
    chk(v == rptr_sh[2] + 16, "P4: all 16 ring writes completed");
    for (int n = 0; n < 4; n++)
      send_rx(2, mk_pkt(1'b0));  // Overflow packets have no expected ring records.
    v = 0;
    for (int t = 0; t < 3000 && !v[2]; t++) apb_rd(A_RV(2, 8'h14), v);
    chk(v[2], "P4: overflow status set");
    apb_rd(A_IRQ_RAW, v2);
    chk(v2[27], "P4: overflow interrupt set");
    apb_rd(A_RV(2, 8'h18), v);
    chk(v == rptr_sh[2] + 16, $sformatf("P4: WPTR stays at 16 records (got %0d)", v - rptr_sh[2]));
    apb_wr(A_RV(2, 8'h14), 32'h7); apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    consume(2, rptr_sh[2] + 16);  // Check the sixteen retained records.
    $display("P4 done (%0d checks, %0d errs)", checks, errs);

    // P5: Backpressure with concurrent host consumption.
    apb_wr(A_RV(1, 8'h10), 32'h0);  // Disable the channel.
    apb_wr(A_RV(1, 8'h10), 32'h0303);  // Enable backpressure and both event interrupts.
    cfg_settle();
    fork
      begin : t_feed
        for (int n = 0; n < 48; n++) feed(1, n == 47);  // Send 48 records into a 32-record ring.
      end
      begin : t_cons
        logic [31:0] wp;
        wp = 0;
        for (int n = 0; n < 3000 && wp != rptr_sh[1] + 32; n++)
          apb_rd(A_RV(1, 8'h18), wp);
        chk(wp == rptr_sh[1] + 32, "P5: ring is full before host consumption");
        chk(lv_rx_tready[1] == 1'b0, "P5: full ring backpressures port 1");
        consume(1, rptr_sh[1] + 48);
      end
    join
    consume(1, rptr_sh[1]);  // Finish any remaining host consumption.
    chk(exp_q[1].size() == 0, "P5: all 48 records checked without loss");
    $display("P5 done (%0d checks, %0d errs)", checks, errs);

    // P6: Disabled-channel discard.
    apb_rd(A_RV(0, 8'h18), v); base_wp = v;
    apb_wr(A_RV(0, 8'h10), 32'h0);  // Disable channel 0.
    cfg_settle();
    // Discarded packets are excluded from the reference queue.
    for (int n = 0; n < 5; n++) send_rx(0, mk_pkt(1'b0));
    #2us;
    apb_rd(A_RV(0, 8'h18), v);
    chk(v == base_wp, "P6: WPTR stays unchanged while disabled");
    apb_rd(A_RV(0, 8'h14), v);
    chk(!v[2], "P6: disabled discard does not set OVF");
    apb_wr(A_RV(0, 8'h10), 32'h0301);  // Re-enable channel 0 with drop-on-overflow policy.
    cfg_settle();
    feed(0, 1'b0); consume(0, rptr_sh[0] + 1);
    $display("P6 done (%0d checks, %0d errs)", checks, errs);

    // P7: AXI write-error notification.
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    ring_cfg(0, 64'h100_0000_0000, 64, 8, 1'b0, 1'b1, 1'b1);  // Select the error address region.
    send_rx(0, mk_pkt(1'b0));  // The failed write has no valid expected record.
    v = 0;
    for (int t = 0; t < 3000 && !v[28]; t++) apb_rd(A_IRQ_RAW, v);
    chk(v[28], "P7: AXI write error interrupt set");
    apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
    // An error response still advances WPTR; skip that slot before recovery.
    rptr_sh[0]++;  // Skip the failed write slot.
    apb_wr(A_RV(0, 8'h1C), rptr_sh[0]);
    ring_cfg(0, 64'h0000_2000_0000, 64, 8, 1'b0, 1'b1, 1'b1);
    feed(0, 1'b0); consume(0, rptr_sh[0] + 1);
    $display("P7 done (%0d checks, %0d errs)", checks, errs);

    // P8: Abort preserves pointers; resume after the host drains the ring.
    apb_wr(A_RV(2, 8'h10), 32'h0);
    apb_wr(A_RV(2, 8'h10), 32'h0103);  // Enable backpressure on channel 2.
    cfg_settle();
    for (int n = 0; n < 16; n++) feed(2, 1'b0);  // Fill the ring.
    v = 0;
    for (int t = 0; t < 3000 && v != rptr_sh[2] + 16; t++) apb_rd(A_RV(2, 8'h18), v);
    chk(v == rptr_sh[2] + 16, "P8: ring is full before abort");
    fork
      begin : t_stuck
        feed(2, 1'b0);  // Keep VALID asserted until the host releases space.
      end
      begin : t_srst
        repeat (4) @(posedge maxi_clk);
        apb_rd(A_RV(2, 8'h18), v); base_wp = v;
        apb_wr(A_GLB_CTRL, 32'h1);
        cfg_settle();
        apb_rd(A_RV(2, 8'h18), v);
        chk(v == base_wp, "P8: abort preserves WPTR");
        chk(!lv_rx_tready[2], "P8: full ring remains backpressured after abort");
        consume(2, rptr_sh[2] + 16);
      end
    join
    consume(2, rptr_sh[2] + 1);  // Check the packet held across abort.
    $display("P8 done (%0d checks, %0d errs)", checks, errs);

    // P9: SEND-to-RECV loopback with concurrent AXI reads and writes.
    // Any channel may receive all 30 records before host consumption starts.
    ring_cfg(2, 64'h0000_2200_0000, 32, 4, 1'b1, 1'b1, 1'b0);
    apb_wr(A_LNK_EN, 32'h007);
    loop_en = 1;
    loopback_writes = wr_land_cnt;
    recs.delete();
    for (int i = 0; i < 30; i++) begin
      automatic int c = $urandom_range(0, 2);
      automatic gold_t g;
      g.is_end = (i == 29); g.pkt = mk_pkt(g.is_end);
      exp_q[c].push_back(g);
      recs.push_back({16'(i), (i == 29) ? 8'h01 : 8'h00, 8'(c), g.pkt});
    end
    foreach (recs[i]) ddr[(64'h0000_3000_0000 >> 4) + i] = recs[i];
    apb_wr(A_S_SRCLO, 32'h3000_0000); apb_wr(A_S_SRCHI, 32'h0);
    apb_wr(A_S_CNT, 30); apb_wr(A_S_DB, 32'h1);
    v = 0;
    for (int t = 0; t < 5000 && !v[8]; t++) apb_rd(A_S_STA, v);
    chk(v[8], "P9: SEND DONE");
    apb_wr(A_S_STA, 32'h300);
    // Consume all expected records, allowing pending writes to finish.
    for (int t = 0; t < 200 &&
         (exp_q[0].size() || exp_q[1].size() || exp_q[2].size()); t++) begin
      logic [31:0] wp;
      for (int c = 0; c < 3; c++) begin
        apb_rd(A_RV(c, 8'h18), wp);
        consume(c, wp);
      end
      #200ns;
    end
    chk(exp_q[0].size() == 0 && exp_q[1].size() == 0 && exp_q[2].size() == 0,
        "P9: all 30 loopback records checked");
    cfg_settle();
    chk(wr_land_cnt - loopback_writes == 30, "P9: exactly 30 loopback writes completed");
    loop_en = 0;
    $display("P9 done (%0d checks, %0d errs)", checks, errs);

    if (errs != 0 || checks == 0) $fatal(1, "RECV TB FAIL (%0d/%0d)", errs, checks);
    $display("RECV TB PASS (%0d checks)", checks);
    $finish;
  end

  initial begin #8ms; $fatal(1, "RECV TB TIMEOUT"); end

endmodule
