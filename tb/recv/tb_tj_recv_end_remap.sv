// File        : tb_tj_recv_end_remap.sv
// Module      : tb_tj_recv_end_remap
// Description : Check END types, channel remapping and receive-ring write addresses.
`timescale 1ns/1ps
module tb_tj_recv_end_remap;
  real pclk_hp = 5.0, maxi_hp = 1.2;
  initial begin
    void'($value$plusargs("TJ_PCLK_HP=%f", pclk_hp));
    void'($value$plusargs("TJ_MAXI_HP=%f", maxi_hp));
  end
  logic pclk = 0, maxi_clk = 0, presetn = 0, maxi_rstn = 0;
  always #(pclk_hp) pclk = ~pclk;
  always #(maxi_hp) maxi_clk = ~maxi_clk;
  logic psel = 0, penable = 0, pwrite = 0, pready, pslverr;
  logic [15:0] paddr = 0;
  logic [31:0] pwdata = 0, prdata;
  logic awvalid, awready, wvalid, wready, wlast, bvalid = 0, bready;
  logic [3:0] awid;
  logic [47:0] awaddr;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;
  logic [127:0] wdata;
  logic [15:0] wstrb;
  logic [3:0] rx_valid = 0, rx_ready, irq;
  logic [3:0][95:0] rx_data = 0;

  tj_ctrl_top u_dut (
    .pclk, .presetn, .maxi_clk, .maxi_rstn,
    .psel, .penable, .pwrite, .paddr, .pwdata, .pready, .pslverr, .prdata,
    .awvalid, .awready, .awid, .awaddr, .awuser(), .awlen, .awsize, .awburst,
    .wvalid, .wready, .wdata, .wstrb, .wlast,
    .bvalid, .bready, .bresp(2'b00), .bid(4'hF),
    .arvalid(), .arready(1'b1), .arid(), .araddr(), .aruser(),
    .arlen(), .arsize(), .arburst(), .rvalid(1'b0), .rready(),
    .rdata(128'b0), .rresp(2'b00), .rlast(1'b0), .rid(4'b0),
    .s_axis_pk_tvalid(1'b0), .s_axis_pk_tready(), .s_axis_pk_tdata(128'b0),
    .s_axis_pk_tlast(1'b0), .m_axis_pk_tvalid(), .m_axis_pk_tready(1'b1),
    .m_axis_pk_tdata(), .m_axis_pk_tlast(), .irq,
    .lv_tx_tvalid(), .lv_tx_tready(4'hF), .lv_tx_tdata(),
    .lv_rx_tvalid(rx_valid), .lv_rx_tready(rx_ready), .lv_rx_tdata(rx_data),
    .lvcfg_din(), .lvcfg_din_vld(), .lvcfg_dout('0), .lvcfg_dout_vld('0),
    .spi_sclk(), .spi_mosi(), .spi_cs_n(), .spi_miso('0),
    .chip_rst_n(), .clkctl(), .uart_rx(1'b1), .uart_tx()
  );

  int checks = 0, errs = 0;
  task automatic chk(input bit ok, input string message);
    checks++;
    if (!ok) begin
      errs++;
      if (errs <= 24) $display("FAIL: %s @%0t", message, $time);
    end
  endtask

  // Capture AW and W independently; acknowledge complete writes after a delay.
  bit hold_b = 0, aw_have = 0, w_have = 0;
  logic [47:0] pending_addr, seen_addr[256];
  logic [127:0] pending_data, seen_data[256];
  int cycle = 0, delay_count = 0, responses = 0;
  assign awready = maxi_rstn && !aw_have && (cycle % 3 != 0);
  assign wready = maxi_rstn && !w_have && (cycle % 4 != 0);
  always @(posedge maxi_clk) begin
    if (!maxi_rstn) begin
      aw_have <= 0; w_have <= 0; bvalid <= 0;
      cycle <= 0; delay_count <= 0; responses <= 0;
    end else begin
      cycle <= cycle + 1;
      if (awvalid && awready) begin
        pending_addr <= awaddr; aw_have <= 1;
        chk(awlen == 0 && awsize == 4 && awburst == 1 && awid == 4'hF,
            "AXI write attributes");
      end
      if (wvalid && wready) begin
        pending_data <= wdata; w_have <= 1;
        chk(wstrb == 16'hFFFF && wlast, "AXI record strobes");
      end
      if (aw_have && w_have && !bvalid && !hold_b) begin
        if (delay_count == 2) begin bvalid <= 1; delay_count <= 0; end
        else delay_count <= delay_count + 1;
      end
      if (bvalid && bready) begin
        seen_addr[responses] = pending_addr;
        seen_data[responses] = pending_data;
        responses <= responses + 1;
        aw_have <= 0; w_have <= 0; bvalid <= 0;
      end
    end
  end

  function automatic logic [15:0] reg_addr(input int c, input logic [7:0] off);
    return 16'h1000 + 16'(c * 64) + 16'(off);
  endfunction
  function automatic logic [95:0] packet(input int id, input logic [3:0] kind);
    return {32'h12345678, 32'(id), 28'h0123456, kind};
  endfunction
  task automatic apb_wr(input logic [15:0] a, input logic [31:0] d);
    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 1; paddr <= a; pwdata <= d;
    @(posedge pclk); penable <= 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    chk(!pslverr, "APB write response");
    psel <= 0; penable <= 0; @(posedge pclk);
  endtask
  task automatic apb_rd(input logic [15:0] a, output logic [31:0] d);
    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 0; paddr <= a;
    @(posedge pclk); penable <= 1;
    @(posedge pclk); while (!pready) @(posedge pclk);
    d = prdata; chk(!pslverr, "APB read response");
    psel <= 0; penable <= 0; @(posedge pclk);
  endtask
  task automatic settle;
    repeat (8) @(negedge maxi_clk);
    repeat (4) @(negedge pclk);
  endtask
  task automatic wait_count(input int expected);
    for (int n = 0; n < 1000 && responses < expected; n++) @(negedge maxi_clk);
    chk(responses == expected, $sformatf("writes=%0d expected=%0d", responses, expected));
    settle();
  endtask
  task automatic send_packet(input int port_id, input logic [95:0] data);
    @(negedge maxi_clk); rx_data[port_id] = data; rx_valid[port_id] = 1;
    @(posedge maxi_clk); while (!rx_ready[port_id]) @(posedge maxi_clk);
    @(negedge maxi_clk); rx_valid[port_id] = 0;
  endtask
  task automatic check_record(input int slot, input int ch, input int offset,
                              input logic [95:0] data, input bit end_flag);
    chk(seen_addr[slot] == 48'h20000000 + 48'(ch * 'h100000 + offset * 16),
        $sformatf("record %0d logical ring address", slot));
    chk(seen_data[slot][95:0] === data, "record packet");
    chk(seen_data[slot][103:96] == 8'(ch), "record logical channel");
    chk(seen_data[slot][111:104] == {7'b0, end_flag}, "record END flag");
  endtask
  task automatic configure(input logic [31:0] remap, input int size0);
    @(negedge pclk); presetn = 0; maxi_rstn = 0; rx_valid = 0;
    repeat (6) @(negedge pclk);
    presetn = 1; maxi_rstn = 1; settle();
    apb_wr(16'h2004, remap); apb_wr(16'h2008, 32'h0000BA98);
    for (int c = 0; c < 3; c++) begin
      apb_wr(reg_addr(c, 8'h00), 32'h20000000 + 32'(c * 'h100000));
      apb_wr(reg_addr(c, 8'h04), 0);
      apb_wr(reg_addr(c, 8'h08), c == 0 ? size0 : 64);
      apb_wr(reg_addr(c, 8'h0C), 32);
    end
    settle();
    for (int c = 0; c < 3; c++) apb_wr(reg_addr(c, 8'h10), 32'h0203);
    settle();
  endtask

  initial begin
    logic [31:0] sta, raw;
    logic [3:0] kind;
    logic [31:0] map;
    int physical, total;
    $display("RECV FEATURES pclk_hp=%0f maxi_hp=%0f", pclk_hp, maxi_hp);

    // P1: Explicit chip END encodings and data/handshake negative controls.
    configure(32'h76543210, 64);
    for (int n = 0; n < 8; n++) begin
      case (n)
        0: kind = 4'h4; 1: kind = 4'h6; 2: kind = 4'hC; 3: kind = 4'hE;
        4: kind = 4'h2; 5: kind = 4'hA; 6: kind = 4'h5; 7: kind = 4'hD;
      endcase
      apb_wr(reg_addr(0, 8'h14), 7); apb_wr(16'h0100, 32'hFFFFFFFF);
      send_packet(0, packet(n, kind)); wait_count(n + 1);
      repeat (80) @(negedge maxi_clk); repeat (8) @(negedge pclk);
      check_record(n, 0, n, packet(n, kind), n < 4);
      apb_rd(reg_addr(0, 8'h14), sta); apb_rd(16'h0100, raw);
      chk(sta[1] == (n < 4), $sformatf("END status for ptype=%h", kind));
      chk(raw[12] == (n < 4), $sformatf("END interrupt for ptype=%h", kind));
    end
    $display("P1 complete (%0d checks, %0d errors)", checks, errs);

    // P2: Identity, swap, and a non-self-inverse three-channel permutation.
    configure(32'h76543210, 64); total = 0;
    for (int mode = 0; mode < 3; mode++) begin
      for (int c = 0; c < 3; c++) apb_wr(reg_addr(c, 8'h10), 0);
      settle();
      map = mode == 0 ? 32'h76543210 : mode == 1 ? 32'h76543201 : 32'h76543021;
      apb_wr(16'h2004, map); settle();
      for (int c = 0; c < 3; c++) apb_wr(reg_addr(c, 8'h10), 32'h0203);
      settle();
      for (int c = 0; c < 3; c++) begin
        physical = mode == 0 ? c : mode == 1 ? (c == 2 ? 2 : 1-c) : (c+1)%3;
        kind = c == 0 ? 4'h6 : c == 1 ? 4'h4 : 4'h2;
        send_packet(physical, packet(100 + total, kind)); wait_count(total + 1);
        check_record(total, c, mode, packet(100 + total, kind), c != 2);
        total++;
      end
    end
    $display("P2 complete (%0d checks, %0d errors)", checks, errs);

    // P3: Full logical ring 0 backpressures physical port 1 only.
    configure(32'h76543021, 4);
    for (int n = 0; n < 4; n++) begin
      send_packet(1, packet(200+n, 4'h2)); wait_count(n + 1);
      check_record(n, 0, n, packet(200+n, 4'h2), 0);
    end
    chk(!rx_ready[1] && rx_ready[0] && rx_ready[2], "mapped full-ring backpressure");
    fork
      send_packet(1, packet(204, 4'h2));
      begin
        repeat (12) begin
          @(negedge maxi_clk); chk(!rx_ready[1], "full ring must hold the packet");
        end
        send_packet(0, packet(210, 4'h2));
        send_packet(2, packet(211, 4'h2));
        wait_count(6);
        apb_wr(reg_addr(0, 8'h1C), 4);
      end
    join
    wait_count(7);
    check_record(4, 2, 0, packet(210, 4'h2), 0);
    check_record(5, 1, 0, packet(211, 4'h2), 0);
    check_record(6, 0, 0, packet(204, 4'h2), 0);
    $display("P3 complete (%0d checks, %0d errors)", checks, errs);

    // P4: A buffered record keeps its full old address when base and size change.
    configure(32'h76543021, 8);
    for (int n = 0; n < 3; n++) begin
      send_packet(1, packet(300+n, 4'h2)); wait_count(n+1);
      check_record(n, 0, n, packet(300+n, 4'h2), 0);
    end
    apb_wr(reg_addr(0, 8'h1C), 3); settle();
    hold_b = 1;
    send_packet(2, packet(310, 4'h2)); wait(aw_have && w_have);
    send_packet(1, packet(311, 4'h2));
    apb_wr(reg_addr(0, 8'h10), 0); settle();
    apb_wr(reg_addr(0, 8'h00), 32'h30000000);
    apb_wr(reg_addr(0, 8'h04), 1);
    apb_wr(reg_addr(0, 8'h08), 2); settle();
    chk(responses == 3, "P4: old record remains buffered behind the held write");
    hold_b = 0; wait_count(5);
    check_record(3, 1, 0, packet(310, 4'h2), 0);
    check_record(4, 0, 3, packet(311, 4'h2), 0);
    apb_rd(reg_addr(0, 8'h18), sta);
    chk(sta == 4, "P4: old-ring write advances the channel pointer once");
    apb_wr(reg_addr(0, 8'h1C), 4); settle();
    apb_wr(reg_addr(0, 8'h10), 32'h0203); settle();
    send_packet(1, packet(312, 4'h2)); wait_count(6);
    chk(seen_addr[5] == 48'h000130000000, "P4: new record uses the new base and size");
    chk(seen_data[5][95:0] === packet(312, 4'h2), "P4: new record payload");
    chk(seen_data[5][103:96] == 0, "P4: new record retains its logical channel");
    $display("P4 complete (%0d checks, %0d errors)", checks, errs);

    // P5: Changing SIZE alone must not change the buffered record's old slot.
    configure(32'h76543210, 16);
    for (int n = 0; n < 6; n++) begin
      send_packet(0, packet(400+n, 4'h2)); wait_count(n+1);
      check_record(n, 0, n, packet(400+n, 4'h2), 0);
    end
    apb_wr(reg_addr(0, 8'h1C), 6); settle();
    hold_b = 1;
    send_packet(1, packet(410, 4'h2)); wait(aw_have && w_have);
    send_packet(0, packet(411, 4'h2));
    apb_wr(reg_addr(0, 8'h10), 0); settle();
    apb_wr(reg_addr(0, 8'h08), 4); settle();
    hold_b = 0; wait_count(8);
    check_record(6, 1, 0, packet(410, 4'h2), 0);
    check_record(7, 0, 6, packet(411, 4'h2), 0);
    apb_wr(reg_addr(0, 8'h1C), 7); settle();
    apb_wr(reg_addr(0, 8'h10), 32'h0203); settle();
    send_packet(0, packet(412, 4'h2)); wait_count(9);
    check_record(8, 0, 3, packet(412, 4'h2), 0);
    $display("P5 complete (%0d checks, %0d errors)", checks, errs);

    if (errs != 0 || checks == 0) $fatal(1, "RECV FEATURES TB FAIL (%0d/%0d)", errs, checks);
    $display("RECV FEATURES TB PASS (%0d checks)", checks);
    $finish;
  end
  initial begin #10ms; $fatal(1, "RECV FEATURES TB TIMEOUT"); end
endmodule
