// File        : tb_tj_init_replay.sv
// Module      : tb_tj_init_replay
// Description : Replay W/P commands through APB, SPIWIN and the chip SPI-to-AHB bridge.
//               Check observed AHB transactions. Skip B/F markers; the model supplies IDLE=1.
// Usage       : +REGS=<init_regs.txt>
module tb_tj_init_replay;
  timeunit 1ns;
  timeprecision 1ps;

  logic pclk = 0, presetn = 0, maxi_clk = 0, maxi_rstn = 0;
  always #5   pclk = ~pclk;         // 100 MHz.
  always #3.7 maxi_clk = ~maxi_clk;  // 135.1 MHz.

  int unsigned errs = 0, checks = 0;
  task automatic chk(input bit c, input string m);
    checks++;
    if (!c) begin
      errs++;
      $display("INIT REPLAY TB FAIL: %s @%0t", m, $time);
    end
  endtask

  // Controller top-level ports.
  logic psel, penable, pwrite;
  logic [15:0] paddr;
  logic [31:0] pwdata, prdata;
  logic pready, pslverr;
  logic [3:0] irq;
  logic [31:0] chip_rst_n;
  logic [3:0] clkctl;
  logic [7:0] sclk, mosi;
  logic [31:0] cs_n, miso;

  tj_ctrl_top u_dut (
    .pclk, .presetn, .maxi_clk, .maxi_rstn,
    .psel, .penable, .pwrite, .paddr, .pwdata, .pready, .pslverr, .prdata,
    .awvalid(), .awready(1'b0), .awid(), .awaddr(), .awuser(), .awlen(), .awsize(), .awburst(),
    .wvalid(), .wready(1'b0), .wdata(), .wstrb(), .wlast(),
    .bvalid(1'b0), .bready(), .bresp(2'b0), .bid('0),
    .arvalid(), .arready(1'b0), .arid(), .araddr(), .aruser(), .arlen(), .arsize(), .arburst(),
    .rvalid(1'b0), .rready(), .rdata('0), .rresp(2'b0), .rlast(1'b0), .rid('0),
    .s_axis_pk_tvalid(1'b0), .s_axis_pk_tready(), .s_axis_pk_tdata('0), .s_axis_pk_tlast(1'b0),
    .m_axis_pk_tvalid(), .m_axis_pk_tready(1'b0), .m_axis_pk_tdata(), .m_axis_pk_tlast(),
    .irq(irq),
    .lv_tx_tvalid(), .lv_tx_tready('0), .lv_tx_tdata(),
    .lv_rx_tvalid('0), .lv_rx_tready(), .lv_rx_tdata('0),
    .lvcfg_din(), .lvcfg_din_vld(), .lvcfg_dout('0), .lvcfg_dout_vld('0),
    .spi_sclk(sclk), .spi_mosi(mosi), .spi_cs_n(cs_n), .spi_miso(miso),
    .chip_rst_n(chip_rst_n), .clkctl(clkctl),
    .uart_rx(1'b1), .uart_tx()
  );

  // Chip SPI-to-AHB bridge, connected to die 0.
  logic [31:0] haddr, hwdata, hrdata;
  logic [2:0]  hburst, hsize;
  logic [1:0]  htrans;
  logic        hwrite, hready, hresp, hlock;
  logic [3:0]  hprot;
  logic        miso0;

  spi2ahb u_chip (
    .spi_cs_n(cs_n[0]), .spi_sck(sclk[0]), .spi_mosi(mosi[0]), .spi_miso(miso0),
    .hclk(pclk), .hresetn(presetn),
    .hrdata(hrdata), .hready(hready), .hresp(hresp),
    .haddr(haddr), .hburst(hburst), .hmastlock(hlock), .hprot(hprot),
    .hsize(hsize), .htrans(htrans), .hwdata(hwdata), .hwrite(hwrite)
  );
  always_comb begin
    miso = '0;
    miso[0] = miso0;
  end

  // Word storage indexed by the full byte address.
  logic [31:0] mem [int unsigned];
  logic        ap_v, ap_w;
  logic [31:0] ap_a;
  assign hresp  = 1'b0;
  assign hready = 1'b1;
  always_comb begin
    hrdata = '0;
    if (ap_v && !ap_w) hrdata = mem[ap_a];
  end
  always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      ap_v <= 0;
      ap_w <= 0;
      ap_a <= '0;
    end
    else begin
      if (ap_v && ap_w) mem[ap_a] <= hwdata;
      ap_v <= htrans[1];
      ap_a <= haddr;
      ap_w <= hwrite;
    end
  end

  // Capture AHB data phases in transaction order.
  typedef struct { logic [31:0] a, d; } wr_t;
  wr_t     wr_log[$];
  logic [31:0] rd_log[$];
  always @(posedge pclk) if (presetn) begin
    if (ap_v && ap_w) begin
      wr_t w;
      w.a = ap_a;
      w.d = hwdata;
      wr_log.push_back(w);
    end
    if (ap_v && !ap_w) rd_log.push_back(ap_a);
  end

  // APB accesses complete only with known ready and no slave error.
  task automatic apb_wr(input [15:0] a, input [31:0] d);
    @(posedge pclk);
    psel <= 1;
    penable <= 0;
    pwrite <= 1;
    paddr <= a;
    pwdata <= d;
    @(posedge pclk); penable <= 1;
    @(posedge pclk);
    while (!pready) @(posedge pclk);
    chk(pready === 1'b1, $sformatf("APB write PREADY at %04h", a));
    chk(pslverr === 1'b0, $sformatf("APB write PSLVERR at %04h", a));
    psel <= 0;
    penable <= 0;
    @(posedge pclk);
  endtask

  task automatic apb_rd(input [15:0] a, output [31:0] d);
    @(posedge pclk);
    psel <= 1;
    penable <= 0;
    pwrite <= 0;
    paddr <= a;
    @(posedge pclk); penable <= 1;
    @(posedge pclk);
    while (!pready) @(posedge pclk);
    chk(pready === 1'b1, $sformatf("APB read PREADY at %04h", a));
    chk(pslverr === 1'b0, $sformatf("APB read PSLVERR at %04h", a));
    d = prdata;
    psel <= 0;
    penable <= 0;
    @(posedge pclk);
  endtask

  // Update the SPIWIN page only when the high address bits change.
  logic [19:0] cur_offs = 20'hFFFFF;
  task automatic win_access(input bit wr, input [31:0] a, inout [31:0] d);
    if (a[31:12] != cur_offs) begin
      apb_wr(16'h3C08, {12'h0, a[31:12]});   // SPIWIN.OFFS
      cur_offs = a[31:12];
    end
    if (wr) apb_wr({4'h4, a[11:0]}, d);
    else    apb_rd({4'h4, a[11:0]}, d);
  endtask

  // Replay initialization commands. F markers belong to the chip integration test.
  string regs_p, line, op, extra;
  int fd, code, n_w, n_p, n_f, poll_i, line_no;
  logic [31:0] a_v, d_v, m_v, v_v, rdat;
  wr_t exp_q[$];
  logic [31:0] exp_rd_q[$];

  initial begin
    psel = 0;
    penable = 0;
    pwrite = 0;
    paddr = '0;
    pwdata = '0;
    n_w = 0;
    n_p = 0;
    n_f = 0;
    line_no = 0;
    repeat (8) @(posedge pclk);
    @(negedge pclk);
    presetn = 1;
    maxi_rstn = 1;
    repeat (8) @(posedge pclk);

    if (!$value$plusargs("REGS=%s", regs_p)) $fatal(1, "need +REGS=");
    fd = $fopen(regs_p, "r");
    if (fd == 0) $fatal(1, "cannot open %s", regs_p);

    // The model reports idle without executing a core program.
    mem[32'h02080018] = 32'h1;

    apb_wr(16'h0410, 32'h1);  // SPI[0].CLKDIV: 25 MHz at pclk=100 MHz.
    apb_wr(16'h3C00, 32'h1);  // Enable SPIWIN.
    apb_wr(16'h3C04, 32'h0);  // Select die 0.

    while ($fgets(line, fd)) begin
      line_no++;
      // Remove full-line and trailing comments before checking operands.
      for (int i = 0; i < line.len(); i++) begin
        if (line.getc(i) == 8'h23) begin
          if (i == 0) line = "";
          else        line = line.substr(0, i - 1);
          break;
        end
      end
      if ($sscanf(line, "%s", op) != 1) continue;
      case (op)
        "W": begin
          wr_t e;
          code = $sscanf(line, "%s %h %h %s", op, a_v, d_v, extra);
          if (code != 3) $fatal(1, "%s:%0d: expected W address data", regs_p, line_no);
          e.a = a_v;
          e.d = d_v;
          exp_q.push_back(e);
          win_access(1'b1, a_v, d_v);
          n_w++;
        end
        "P": begin
          code = $sscanf(line, "%s %h %h %h %s", op, a_v, m_v, v_v, extra);
          if (code != 4) $fatal(1, "%s:%0d: expected P address mask value", regs_p, line_no);
          poll_i = 0;
          do begin
            exp_rd_q.push_back(a_v);
            win_access(1'b0, a_v, rdat);
            poll_i++;
          end while (((rdat & m_v) !== v_v) && poll_i < 20);
          chk((rdat & m_v) === v_v,
              $sformatf("Poll %08h failed after %0d reads: %08h & %08h != %08h",
                        a_v, poll_i, rdat, m_v, v_v));
          n_p++;
        end
        "B", "F": begin
          code = $sscanf(line, "%s %h %h %s", op, a_v, d_v, extra);
          if (code != 3) $fatal(1, "%s:%0d: expected %s argument argument", regs_p, line_no, op);
          if (op == "F") n_f++;
        end
        default: $fatal(1, "%s:%0d: unsupported command %s", regs_p, line_no, op);
      endcase
    end
    $fclose(fd);
    if (n_w + n_p == 0) $fatal(1, "Command list contains no W/P operations");
    repeat (50) @(posedge pclk);

    // Match every observed write and read against the requested transactions.
    chk(wr_log.size() == exp_q.size(),
        $sformatf("AHB writes: got %0d, expected %0d", wr_log.size(), exp_q.size()));
    for (int i = 0; i < exp_q.size() && i < wr_log.size(); i++) begin
      chk(wr_log[i].a === exp_q[i].a && wr_log[i].d === exp_q[i].d,
          $sformatf("Write %0d: got %08h=%08h, expected %08h=%08h",
                    i, wr_log[i].a, wr_log[i].d, exp_q[i].a, exp_q[i].d));
    end
    chk(rd_log.size() == exp_rd_q.size(),
        $sformatf("AHB reads: got %0d, expected %0d", rd_log.size(), exp_rd_q.size()));
    for (int i = 0; i < exp_rd_q.size() && i < rd_log.size(); i++) begin
      chk(rd_log[i] === exp_rd_q[i],
          $sformatf("Read %0d: got %08h, expected %08h", i, rd_log[i], exp_rd_q[i]));
    end

    $display("Replayed %0d writes and %0d polls; skipped %0d SEND markers", n_w, n_p, n_f);
    if (errs == 0 && checks > 0)
      $display("INIT REPLAY TB PASS (%0d checks)", checks);
    else
      $fatal(1, "INIT REPLAY TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end

  initial begin
    #20ms;
    $fatal(1, "INIT REPLAY TB TIMEOUT");
  end
endmodule
