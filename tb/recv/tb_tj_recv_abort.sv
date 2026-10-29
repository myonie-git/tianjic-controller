// File        : tb_tj_recv_abort.sv
// Module      : tb_tj_recv_abort
// Description : Check receive abort backpressure, discard reporting and recovery.
`timescale 1ns/1ps
module tb_tj_recv_abort;
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

  logic edge_done;
  int edge_checks, edge_errors;
  recv_abort_edge_probe u_edge (
    .clk(maxi_clk), .done_o(edge_done), .checks_o(edge_checks), .errors_o(edge_errors)
  );

  task automatic events_settle;
    repeat (80) @(negedge maxi_clk);
    repeat (8) @(negedge pclk);
  endtask

  initial begin
    logic [31:0] sta, raw, wp;
    $display("RECV ABORT pclk_hp=%0f maxi_hp=%0f", pclk_hp, maxi_hp);

    // P1: Preserve the blocked packet under backpressure until the old write drains.
    configure(32'h76543021, 64);
    hold_b = 1;
    send_packet(0, packet(10, 4'h6));
    wait (aw_have && w_have);
    send_packet(1, packet(11, 4'h2)); // Buffered logical channel 0; abort discards it.
    apb_wr(16'h000C, 1); settle();
    apb_rd(reg_addr(2, 8'h18), wp);
    chk(wp == 0, "outstanding write is not complete before B response");
    fork
      send_packet(2, packet(12, 4'h2));
      begin
        repeat (12) begin
          @(negedge maxi_clk);
          chk(!rx_ready[2], "POL=1 backpressures the remapped port during drain");
        end
        chk(responses == 0, "abort does not complete the held AXI write");
        hold_b = 0;
      end
    join
    wait_count(2); events_settle();
    check_record(0, 2, 0, packet(10, 4'h6), 1);
    check_record(1, 1, 0, packet(12, 4'h2), 0);
    apb_rd(reg_addr(0, 8'h18), wp);
    chk(wp == 0, "abort flushes buffered records without advancing their pointer");
    apb_rd(reg_addr(2, 8'h18), wp);
    chk(wp == 1, "outstanding write advances its original channel once");
    apb_rd(reg_addr(2, 8'h14), sta);
    chk(sta[1], "END response is reported while draining");
    apb_rd(reg_addr(1, 8'h14), sta);
    chk(!sta[2], "backpressured packet does not report overflow");
    $display("P1 complete (%0d checks, %0d errors)", checks, errs);

    // P2: Drop-mode packets during drain report OVF, including after W1C.
    configure(32'h76543021, 64);
    apb_wr(reg_addr(1, 8'h10), 32'h0201);
    apb_wr(reg_addr(0, 8'h10), 0);
    settle(); hold_b = 1;
    send_packet(0, packet(20, 4'h2));
    wait (aw_have && w_have);
    apb_wr(16'h000C, 1); settle();
    for (int n = 0; n < 3; n++) send_packet(2, packet(21+n, 4'h2));
    send_packet(1, packet(24, 4'h2)); // Disabled logical channel 0.
    send_packet(3, packet(25, 4'h2)); // Unused physical port.
    events_settle();
    chk(responses == 0, "drop-mode packets cannot issue writes while draining");
    apb_rd(reg_addr(1, 8'h14), sta); apb_rd(16'h0100, raw);
    chk(sta[2], "POL=0 drain discard sets channel OVF");
    chk(raw[27], "POL=0 drain discard reaches IRQ.RAW[27]");
    apb_rd(reg_addr(0, 8'h14), sta);
    chk(!sta[2], "disabled-channel discard remains unreported");
    apb_wr(reg_addr(1, 8'h14), 4); apb_wr(16'h0100, 32'h08000000);
    events_settle();
    apb_rd(reg_addr(1, 8'h14), sta);
    chk(!sta[2], "W1C clears OVF after the event settles");
    send_packet(2, packet(26, 4'h2)); events_settle();
    apb_rd(reg_addr(1, 8'h14), sta);
    chk(sta[2], "a later drain discard can set OVF again");
    hold_b = 0; wait_count(1); events_settle();
    check_record(0, 2, 0, packet(20, 4'h2), 0);
    apb_rd(reg_addr(1, 8'h18), wp);
    chk(wp == 0, "discarded drain packets never advance WPTR");
    send_packet(2, packet(27, 4'h2)); wait_count(2);
    check_record(1, 1, 0, packet(27, 4'h2), 0);
    $display("P2 complete (%0d checks, %0d errors)", checks, errs);

    // P3 runs at the engine boundary to check the exact abort sampling edge.
    wait (edge_done);
    checks += edge_checks; errs += edge_errors;
    if (errs != 0 || checks == 0) $fatal(1, "RECV ABORT TB FAIL (%0d/%0d)", errs, checks);
    $display("RECV ABORT TB PASS (%0d checks)", checks);
    $finish;
  end
  initial begin #10ms; $fatal(1, "RECV ABORT TB TIMEOUT"); end
endmodule

// Check the abort edge through public engine ports; no internal hierarchy access.
module recv_abort_edge_probe (
  input logic clk,
  output logic done_o = 0,
  output int checks_o = 0,
  output int errors_o = 0
);
  logic rst_n = 0, abort = 0;
  logic [2:0][47:0] cfg_base;
  logic [2:0][31:0] cfg_size, cfg_wmark;
  logic [2:0][31:0] wptr;
  logic [2:0][15:0] level;
  logic [2:0] evt_wmark, evt_end, evt_ovf;
  logic [3:0] rx_tvalid = 0, rx_tready;
  logic [3:0][95:0] rx_tdata = 0;
  logic wr_valid, wr_ready = 0, wr_done = 0;
  logic [47:0] wr_addr;
  logic [127:0] wr_data;
  bit accepted_early;
  tj_recv_engine #(.AW(48)) dut (
    .clk, .rst_n, .abort, .ts(48'h1234), .cfg_base, .cfg_size, .cfg_wmark,
    .cfg_en(3'b011), .cfg_pol(3'b001), .cfg_remap0(32'h76543210),
    .cfg_remap1(16'hBA98), .rptr(96'b0), .wptr, .level, .evt_wmark, .evt_end, .evt_ovf,
    .rx_tvalid, .rx_tready, .rx_tdata, .wr_valid, .wr_ready, .wr_addr, .wr_data,
    .wr_done, .wr_idle(1'b1)
  );
  task automatic chk(input bit ok, input string msg);
    checks_o++;
    if (!ok) begin errors_o++; $display("FAIL abort edge: %s @%0t", msg, $time); end
  endtask
  initial begin
    for (int c=0;c<3;c++) begin
      cfg_base[c]=48'h20000000+48'(c*'h100000); cfg_size[c]=64; cfg_wmark[c]=32;
      rx_tdata[c]={32'h12345678,32'(c),32'h00000002};
    end
    repeat (6) @(negedge clk); rst_n=1;
    repeat (3) @(negedge clk); abort=1; rx_tvalid=4'b0111;
    @(posedge clk);
    accepted_early=rx_tready[0];
    chk(!rx_tready[0], "POL=1 must not accept on the abort edge");
    chk(rx_tready[1], "POL=0 may discard on the abort edge");
    chk(rx_tready[2], "disabled channel continues to accept and discard");
    @(negedge clk);
    chk(evt_ovf==3'b010, "only the enabled POL=0 discard reports OVF");
    abort=0; rx_tvalid=accepted_early ? 0 : 1;
    if (!accepted_early) begin
      @(posedge clk); while (!rx_tready[0]) @(posedge clk);
      @(negedge clk); rx_tvalid=0;
    end
    for (int n=0;n<20 && !wr_valid;n++) @(negedge clk);
    chk(wr_valid, "the backpressured packet is available after abort");
    if (wr_valid) begin
      chk(wr_data[95:0]===rx_tdata[0], "recovered packet data");
      chk(wr_addr==48'h20000000, "recovered packet address");
      wr_ready=1; @(posedge clk); @(negedge clk); wr_ready=0;
      wr_done=1; @(posedge clk); @(negedge clk); wr_done=0;
      chk(wptr[0]==1 && wptr[1]==0 && wptr[2]==0, "only the retained packet completes");
    end
    done_o=1;
  end
endmodule
