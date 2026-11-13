// File        : tb_tj_lnk.sv
// Module      : tb_tj_lnk
// Description : Verify configuration access and bidirectional LVDS packet traffic.
//               Default mode links two controller LVDS copies over four logical ports with
//               random backpressure. EXTERNAL_TLAST_TEST pairs a copy using external TLAST
//               with the original SOC LVDS.
// Compile chip RTL with FOR_SIM_ONLY and a 1 ps / 1 fs timescale.

module tb_tj_lnk #(parameter bit EXTERNAL_TLAST_TEST = 0);
  `include "tj_case_select.svh"
  import tj_ctrl_pkg::*;

  // Independent data clocks; both configuration ports use clk_a.
  // AXIS frequency must be at least one quarter of the transmit bit-clock frequency.
  // +SLOW_ACLK selects a diagnostic case that violates this constraint.
  logic clk_a = 0, clk_b = 0, bclk_a = 0, bclk_b = 0, rstn = 0;
  real  ha_ps = 1250.0, hb_ps = 1287.5;
  initial if ($test$plusargs("SLOW_ACLK")) begin
    ha_ps = 5000.0;
    hb_ps = 5150.0;
  end
  always #(ha_ps) clk_a  = ~clk_a;
  always #(hb_ps) clk_b  = ~clk_b;
  always #0.500ns bclk_a = ~bclk_a;
  always #0.5075ns bclk_b = ~bclk_b;

  int unsigned errs = 0, checks = 0;
  task automatic chk(input bit c, input string m);
    checks++;
    if (!c) begin
      errs++;
      $display("FAIL: %s @%0t", m, $time);
    end
  endtask

  // Configuration-chain master.
  logic        db_go;
  logic [1:0]  kind, inst;
  logic [31:0] wdata, rdata;
  logic        busy, dvld;
  logic [32:0] ccm_din;
  logic        ccm_din_vld;
  logic [31:0] a_dout;
  logic        a_dout_vld;

  tj_cfgchain_master u_ccm (
    .clk(clk_a), .rst_n(rstn),
    .db_go(db_go), .kind(kind), .inst(inst), .wdata(wdata),
    .rdata_o(rdata), .busy_o(busy), .dvld_set_o(dvld),
    .din(ccm_din), .din_vld(ccm_din_vld),
    .dout(a_dout), .dout_vld(a_dout_vld)
  );

  // Two chip LVDS instances with chained configuration and crossed differential I/O.
  logic [1:0]  a_idn, b_idn;
  logic [3:0]        a_sv, a_sr, a_mv, a_mr, b_sv, b_sr, b_mv, b_mr;
  logic [3:0][95:0]  a_sd, a_md, b_sd, b_md;
  logic [32:0] a2b_din;
  logic        a2b_vld;
  logic [31:0] b2a_dout;
  logic        b2a_vld;
  logic        a_err, b_err, a_sm, b_sm;
  wire [2:0]        ab_c_p, ab_c_n, ba_c_p, ba_c_n;
  wire [2:0][4:0]   ab_d_p, ab_d_n, ba_d_p, ba_d_n;

  logic [3:0] a_sl;
  int unsigned a_checked_records, a_checked_groups;
  generate if (EXTERNAL_TLAST_TEST) begin : g_tlast
    tj_lnk_plug_tlast u_a (
      .s_tlast(a_sl), .checked_records(a_checked_records), .checked_groups(a_checked_groups),
      .core_id(2'd0), .core_id_next(a_idn),
      .apb_pclk(clk_a), .axis_brg_clk(clk_a), .lvds_tx_bclk(bclk_a), .rstn_raw(rstn),
      .s_tvalid(a_sv), .s_tready(a_sr), .s_tdata(a_sd),
      .m_tvalid(a_mv), .m_tready(a_mr), .m_tdata(a_md),
      .cfg_din(ccm_din), .cfg_din_vld(ccm_din_vld),
      .cfg_dout(a_dout), .cfg_dout_vld(a_dout_vld),
      .cfg_din_next(a2b_din), .cfg_din_next_vld(a2b_vld),
      .cfg_dout_next(b2a_dout), .cfg_dout_next_vld(b2a_vld),
      .err_intr(a_err), .send_mode(a_sm),
      .txc_p(ab_c_p), .txc_n(ab_c_n), .txd_p(ab_d_p), .txd_n(ab_d_n),
      .rxc_p(ba_c_p), .rxc_n(ba_c_n), .rxd_p(ba_d_p), .rxd_n(ba_d_n)
    );
  end else begin : g_legacy
    tj_lnk_plug_chip u_a (
      .core_id(2'd0), .core_id_next(a_idn),
      .apb_pclk(clk_a), .axis_brg_clk(clk_a), .lvds_tx_bclk(bclk_a), .rstn_raw(rstn),
      .s_tvalid(a_sv), .s_tready(a_sr), .s_tdata(a_sd),
      .m_tvalid(a_mv), .m_tready(a_mr), .m_tdata(a_md),
      .cfg_din(ccm_din), .cfg_din_vld(ccm_din_vld),
      .cfg_dout(a_dout), .cfg_dout_vld(a_dout_vld),
      .cfg_din_next(a2b_din), .cfg_din_next_vld(a2b_vld),
      .cfg_dout_next(b2a_dout), .cfg_dout_next_vld(b2a_vld),
      .err_intr(a_err), .send_mode(a_sm),
      .txc_p(ab_c_p), .txc_n(ab_c_n), .txd_p(ab_d_p), .txd_n(ab_d_n),
      .rxc_p(ba_c_p), .rxc_n(ba_c_n), .rxd_p(ba_d_p), .rxd_n(ba_d_n)
    );
  end endgenerate

  tj_lnk_plug_chip u_b (
    .core_id(a_idn), .core_id_next(b_idn),
    .apb_pclk(clk_a), .axis_brg_clk(clk_b), .lvds_tx_bclk(bclk_b), .rstn_raw(rstn),
    .s_tvalid(b_sv), .s_tready(b_sr), .s_tdata(b_sd),
    .m_tvalid(b_mv), .m_tready(b_mr), .m_tdata(b_md),
    .cfg_din(a2b_din), .cfg_din_vld(a2b_vld),
    .cfg_dout(b2a_dout), .cfg_dout_vld(b2a_vld),
    .cfg_din_next(), .cfg_din_next_vld(),
    .cfg_dout_next(32'h0), .cfg_dout_next_vld(1'b0),
    .err_intr(b_err), .send_mode(b_sm),
    .txc_p(ba_c_p), .txc_n(ba_c_n), .txd_p(ba_d_p), .txd_n(ba_d_n),
    .rxc_p(ab_c_p), .rxc_n(ab_c_n), .rxd_p(ab_d_p), .rxd_n(ab_d_n)
  );

  // Register access through the public configuration-master ports.
  task automatic cc_op(input [1:0] k, input [1:0] i, input [31:0] w);
    @(posedge clk_a);
    kind <= k;
    inst <= i;
    wdata <= w;
    @(posedge clk_a);
    db_go <= 1'b1;
    @(posedge clk_a);
    db_go <= 1'b0;
    @(posedge clk_a);
    while (busy) @(posedge clk_a);
  endtask

  // Send on the first idle cycle, without an added settling delay.
  task automatic cc_op_when_idle(input [1:0] k, input [1:0] i, input [31:0] w);
    @(negedge clk_a);
    while (busy) @(negedge clk_a);
    kind = k;
    inst = i;
    wdata = w;
    db_go = 1'b1;
    @(negedge clk_a);
    db_go = 1'b0;
  endtask

  task automatic cc_write(input [1:0] i, input [24:0] a, input [31:0] d);
    cc_op(2'd0, i, {7'h0, a});
    cc_op(2'd1, i, d);
  endtask

  bit saw_dvld;
  always @(posedge clk_a) if (dvld) saw_dvld = 1;
  task automatic cc_read(input [1:0] i, input [24:0] a, output [31:0] d);
    saw_dvld = 0;
    cc_op(2'd2, i, {7'h0, a});
    repeat (2) @(posedge clk_a);
    chk(saw_dvld, $sformatf("Instance %0d read %h returned no data", i, a));
    d = rdata;
  endtask

  // Latch error events until the end of the traffic phase.
  bit a_err_seen, b_err_seen;
  always @(posedge clk_a) begin
    if (a_err) a_err_seen <= 1'b1;
    if (b_err) b_err_seen <= 1'b1;
  end

  // Collect accepted packets per logical port.
  logic [95:0] rxq_b [4][$];
  logic [95:0] rxq_a [4][$];
  always @(posedge clk_b) for (int p = 0; p < 4; p++)
    if (b_mv[p] && b_mr[p]) rxq_b[p].push_back(b_md[p]);
  always @(posedge clk_a) for (int p = 0; p < 4; p++)
    if (a_mv[p] && a_mr[p]) rxq_a[p].push_back(a_md[p]);

  bit hold_b = 0;
  int unsigned tx_stalls = 0, rx_stalls = 0, contested_cycles = 0, gap_cycles = 0;
  always @(posedge clk_a) if (rstn && EXTERNAL_TLAST_TEST) begin
    if (|(a_sv & ~a_sr)) tx_stalls++;
    if ($countones(a_sv) > 1) contested_cycles++;
  end
  always @(posedge clk_b) if (rstn && EXTERNAL_TLAST_TEST && |(b_mv & ~b_mr)) rx_stalls++;

  // Random backpressure in each receiver clock domain.
  always @(posedge clk_b) for (int p = 0; p < 4; p++) b_mr[p] <= !hold_b && ($urandom_range(0,3) != 0);
  always @(posedge clk_a) for (int p = 0; p < 4; p++) a_mr[p] <= ($urandom_range(0,3) != 0);

  task automatic send_a(input int p, input logic [95:0] d, input bit last = 1);
    @(posedge clk_a);
    a_sd[p] <= d;
    a_sl[p] <= last;
    a_sv[p] <= 1'b1;
    @(posedge clk_a);
    while (!a_sr[p]) @(posedge clk_a);
    a_sv[p] <= 1'b0;
  endtask
  task automatic send_b(input int p, input logic [95:0] d);
    @(posedge clk_b);
    b_sd[p] <= d;
    b_sv[p] <= 1'b1;
    @(posedge clk_b);
    while (!b_sr[p]) @(posedge clk_b);
    b_sv[p] <= 1'b0;
  endtask

  localparam int N_PKT = 40;

  // 0x211F enables auto-sleep; +GRP210F disables it.
  logic [31:0] GRP_PARAM = (8 << 10) | (8 << 5) | 5'h1F;
  initial if ($test$plusargs("GRP210F")) GRP_PARAM = (8 << 10) | (8 << 5) | 5'h0F;
  logic [95:0] exp_ab [4][$];
  logic [95:0] exp_ba [4][$];
  logic [31:0] rd32;
  logic [95:0] pkt;

  bit links_ready = 0, traffic_checked = 0;
  task automatic configure_links;
    for (int i = 0; i < 2; i++) begin
      cc_write(2'(i), 25'h04, GRP_PARAM);
      cc_write(2'(i), 25'h24, GRP_PARAM);
      cc_write(2'(i), 25'h44, GRP_PARAM);
      cc_write(2'(i), 25'h00, 32'h4);

      cc_write(2'(i), 25'h200, 32'h0);

    end
    #5us;

    // Clear startup errors before monitoring traffic.
    for (int i = 0; i < 2; i++) begin
      cc_read (2'(i), 25'h204, rd32);
      chk(rd32[11:0] != '0, $sformatf("Instance %0d startup errors must be latched: %h", i, rd32));
      cc_write(2'(i), 25'h204, 32'hFFF);
      cc_read (2'(i), 25'h204, rd32);
      chk(rd32 === 32'h0, $sformatf("Instance %0d ERR_ST after clear: %h", i, rd32));
    end
    a_err_seen = 0;
    b_err_seen = 0;
    links_ready = 1;
  endtask

  task automatic exercise_links;
    for (int p = 0; p < 4; p++) begin
      for (int n = 0; n < N_PKT; n++) begin

        pkt = {({$urandom, $urandom} & 64'hFFFF_FFFF_FFFF_FFFF),
               14'($urandom), 6'($urandom), 6'($urandom), 2'(p), 4'b0010};
        exp_ab[p].push_back(pkt);
        send_a(p, pkt);
      end
    end
    for (int p = 0; p < 4; p++) begin
      for (int n = 0; n < N_PKT; n++) begin
        pkt = {({$urandom, $urandom} & 64'hFFFF_FFFF_FFFF_FFFF),
               14'($urandom), 6'($urandom), 6'($urandom), 2'(p), 4'b0010};
        exp_ba[p].push_back(pkt);
        send_b(p, pkt);
      end
    end
    #20us;

    // Packets can arrive out of order across physical links; compare per-port multisets.
    for (int p = 0; p < 4; p++) begin
      logic [95:0] eq[$], gq[$];
      chk(rxq_b[p].size() == N_PKT,
          $sformatf("A to B port %0d received %0d/%0d", p, rxq_b[p].size(), N_PKT));
      eq = exp_ab[p];
      gq = rxq_b[p];
      eq.sort();
      gq.sort();
      for (int n = 0; n < gq.size() && n < N_PKT; n++)
        chk(gq[n] === eq[n],
            $sformatf("A to B port %0d packet %0d: %h vs %h", p, n, gq[n], eq[n]));
      chk(rxq_a[p].size() == N_PKT,
          $sformatf("B to A port %0d received %0d/%0d", p, rxq_a[p].size(), N_PKT));
      eq = exp_ba[p];
      gq = rxq_a[p];
      eq.sort();
      gq.sort();
      for (int n = 0; n < gq.size() && n < N_PKT; n++)
        chk(gq[n] === eq[n],
            $sformatf("B to A port %0d packet %0d: %h vs %h", p, n, gq[n], eq[n]));
    end
    traffic_checked = 1;
  endtask


  // 1/2/3 records and groups longer than a physical frame (4/7/17 records).
  localparam int N_GROUPS = 6, N_TLAST_RECORDS = 34;
  function automatic int group_size(input int g);
    case (g)
      0: return 1; 1: return 2; 2: return 3;
      3: return 4; 4: return 7; default: return 17;
    endcase
  endfunction
  function automatic logic [95:0] grouped_packet(input int p, g, n);
    return {32'h544c4153, 8'(p), 8'(g), 16'(n), 26'h123456, 2'(p), 4'b0010};
  endfunction
  task automatic send_groups(input int p);
    for (int g = 0; g < N_GROUPS; g++) begin
      for (int n = 0; n < group_size(g); n++) begin
        // Pause inside an unfinished group, including just before its TLAST.
        if (n != 0 && (n == 1 || n == group_size(g)-1)) begin
          repeat (5+p) @(posedge clk_a);
          gap_cycles++;
        end
        send_a(p, grouped_packet(p,g,n), n == group_size(g)-1);
      end
    end
  endtask
  task automatic exercise_tlast;
    int seen[4][N_GROUPS];
    for (int p = 0; p < 4; p++)
      for (int g = 0; g < N_GROUPS; g++) seen[p][g] = 0;
    hold_b = 1;
    // Four contenders share three physical links. Reverse traffic is legacy SOC TX.
    fork
      send_groups(0);
      send_groups(1);
      send_groups(2);
      send_groups(3);
      begin
        repeat (2500) @(posedge clk_b);
        hold_b = 0;
      end
      begin
        for (int p = 0; p < 4; p++)
          for (int n = 0; n < 4; n++) send_b(p, grouped_packet(p,0,n));
      end
    join
    #20us;
    for (int p = 0; p < 4; p++) begin
      chk(rxq_b[p].size() == N_TLAST_RECORDS,
          $sformatf("TLAST port %0d count %0d/%0d",p,rxq_b[p].size(),N_TLAST_RECORDS));
      // Different groups may use different physical links. Within a group,
      // require exact sequence and payload, not a sorted multiset.
      for (int i = 0; i < rxq_b[p].size(); i++) begin
        int g;
        g = rxq_b[p][i][55:48];
        chk(g < N_GROUPS, "Received group ID is valid");
        if (g < N_GROUPS) begin
          chk(rxq_b[p][i] === grouped_packet(p,g,seen[p][g]),
              $sformatf("TLAST port %0d group %0d record %0d",p,g,seen[p][g]));
          seen[p][g]++;
        end
      end
      for (int g = 0; g < N_GROUPS; g++)
        chk(seen[p][g] == group_size(g), $sformatf("TLAST group count p%0d g%0d",p,g));
      chk(rxq_a[p].size() == 4, "Legacy SOC return traffic count");
      for (int n = 0; n < 4; n++) begin
        int match_count;
        match_count = 0;
        for (int i = 0; i < rxq_a[p].size(); i++) if (rxq_a[p][i] === grouped_packet(p,0,n)) match_count++;
        chk(match_count == 1, "Legacy SOC return payload exactly once");
      end
    end
    chk(a_checked_records == 4*N_TLAST_RECORDS, "All arbiter outputs checked, including TLAST");
    chk(a_checked_groups == 4*N_GROUPS, "All AXIS groups closed on the expected TLAST");
    chk(tx_stalls > 0 && rx_stalls > 0, "Both transmit and receive backpressure exercised");
    chk(contested_cycles > 0 && gap_cycles > 0, "Concurrent contenders and in-group gaps exercised");
    $display("TLAST COVERAGE records=%0d groups=%0d tx_stalls=%0d rx_stalls=%0d contention=%0d gaps=%0d",
             a_checked_records,a_checked_groups,tx_stalls,rx_stalls,contested_cycles,gap_cycles);
    traffic_checked = 1;
  endtask

  initial begin
    tj_cases_init("T1,T2,T3,T4");
    if (EXTERNAL_TLAST_TEST && tj_case_filter_active)
      $fatal(1, "TLAST test requires all configuration, traffic and error checks");
    db_go = 0;
    kind = '0;
    inst = '0;
    wdata = '0;
    a_sv = '0;
    a_sd = '0;
    a_sl = '1;
    b_sv = '0;
    b_sd = '0;
    #1us rstn = 1;
    #2us;

    // T1: Instance selection, register readback and idle-paced writes.
    if (tj_run_case("T1")) begin
      chk(a_idn === 2'd1 && b_idn === 2'd2, "Chained instance IDs");
      cc_write(2'd0, 25'h64, 32'h0000_1234);
      cc_read (2'd0, 25'h64, rd32);
      chk(rd32[15:0] === 16'h1234, $sformatf("Instance 0 readback: %h", rd32));
      cc_write(2'd1, 25'h64, 32'h0000_2345);
      cc_read (2'd1, 25'h64, rd32);
      chk(rd32[15:0] === 16'h2345, $sformatf("Instance 1 readback: %h", rd32));
      cc_read (2'd0, 25'h64, rd32);
      chk(rd32[15:0] === 16'h1234, "Instance 0 remains unchanged");

      for (int i = 0; i < 2; i++) begin
        logic [15:0] expected;
        expected = (i == 0) ? 16'h3456 : 16'h4567;
        saw_dvld = 0;
        cc_op_when_idle(2'd0, 2'(i), 32'h64);
        cc_op_when_idle(2'd1, 2'(i), {16'h0, expected});
        while (busy) @(negedge clk_a);
        chk(!saw_dvld, $sformatf("inst%0d write must not set DVLD", i));
        cc_read(2'(i), 25'h64, rd32);
        chk(rd32[15:0] === expected,
            $sformatf("inst%0d idle-paced write: got %h, expected %h", i, rd32, expected));
      end
    end

    // T2: Configure three physical links and enable packet traffic.
    if (tj_run_case("T2")) begin
      configure_links();
    end

    // T3: Exercise all four logical ports in both directions.
    if (tj_run_case("T3")) begin
      if (!links_ready) begin
        $display("CASE SETUP T2 for T3");
        configure_links();
      end
      if (EXTERNAL_TLAST_TEST) exercise_tlast();
      else exercise_links();
    end

    // T4: Check latched error events and both error-status registers.
    if (tj_run_case("T4")) begin
      if (!links_ready) begin
        $display("CASE SETUP T2 for T4");
        configure_links();
      end
      if (!traffic_checked) begin
        $display("CASE SETUP T3 for T4");
        if (EXTERNAL_TLAST_TEST) exercise_tlast();
        else exercise_links();
      end
      chk(!a_err_seen && !b_err_seen, "No error interrupt during packet traffic");
      cc_read(2'd0, 25'h204, rd32);
      chk(rd32 === 32'h0, $sformatf("A.ERR_ST must be zero: %h", rd32));
      cc_read(2'd1, 25'h204, rd32);
      chk(rd32 === 32'h0, $sformatf("B.ERR_ST must be zero: %h", rd32));
    end

    if (checks > 0 && errs == 0) begin
      if (EXTERNAL_TLAST_TEST) $display("TLAST TB PASS (%0d checks)", checks);
      else $display("LNK TB PASS (%0d checks)", checks);
    end
    else if (EXTERNAL_TLAST_TEST) $display("TLAST TB FAIL (%0d/%0d)", errs, checks);
    else           $display("LNK TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end

  initial begin
    #2ms;
    $fatal(1, "LNK TB TIMEOUT");
  end

endmodule
