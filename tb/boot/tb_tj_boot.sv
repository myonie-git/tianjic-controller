// File        : tb_tj_boot.sv
// Module      : tb_tj_boot
// Description : Exercise BOOT through APB and compare die 0 AHB writes with the DDR image.
`timescale 1ns/1ps
module tb_tj_boot;
  `include "tj_case_select.svh"
  function automatic real half_period(input string key, input real fallback);
    real value;
    if (!$value$plusargs({key, "=%f"}, value)) value = fallback;
    if (value < 0.001) $fatal(1, "%s must be at least 0.001 ns", key);
    return value;
  endfunction

  real pclk_hp = half_period("TJ_PCLK_HP", 5.0);
  real maxi_hp = half_period("TJ_MAXI_HP", 1.2);
  // Scale polling and watchdog budgets for the clock ratio.
  int unsigned tscale = 1;
  logic pclk = 0, presetn = 0, maxi_clk = 0, maxi_rstn = 0;
  logic chip_hclk = 0;
  always #(pclk_hp) pclk = ~pclk;
  always #(maxi_hp) maxi_clk = ~maxi_clk;
  always #5ns chip_hclk = ~chip_hclk;

  int unsigned errs = 0, checks = 0;
  task automatic chk(input bit c, input string m);
    checks++;
    if (!c) begin errs++; $display("FAIL: %s @%0t", m, $time); end
  endtask

  // Controller CSR offsets.
  localparam [15:0] A_GLB_CTRL = 16'h000C;
  localparam [15:0] A_IRQ_RAW  = 16'h0100;
  localparam [15:0] A_SPI_CMD  = 16'h0400;
  localparam [15:0] A_SPI_ADDR = 16'h0404;
  localparam [15:0] A_SPI_WD   = 16'h0408;
  localparam [15:0] A_SPI_DB   = 16'h0418;
  localparam [15:0] A_SPI_STA  = 16'h041C;
  localparam [15:0] A_SPI_DIV  = 16'h0410;
  localparam [15:0] A_SPI_TMO  = 16'h0414;
  localparam [15:0] A_B_CMD    = 16'h0800;
  localparam [15:0] A_B_SRCLO  = 16'h0804;
  localparam [15:0] A_B_SRCHI  = 16'h0808;
  localparam [15:0] A_B_LEN    = 16'h080C;
  localparam [15:0] A_B_DST    = 16'h0810;
  localparam [15:0] A_B_DB     = 16'h0814;
  localparam [15:0] A_B_STA    = 16'h0818;
  localparam [15:0] A_WIN_EN   = 16'h3C00;
  localparam [15:0] A_WIN_PAGE = 16'h3C04;
  localparam [15:0] A_WIN_OFFS = 16'h3C08;

  // Controller ports.
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
  logic [7:0]  sclk_w, mosi_w;
  logic [31:0] cs_w, miso_w;
  wire spi_idle = &cs_w;
  int unsigned spi_frames = 0;
  always @(negedge spi_idle) if (presetn) spi_frames++;

  tj_ctrl_top u_dut (
    .pclk, .presetn, .maxi_clk, .maxi_rstn,
    .psel, .penable, .pwrite, .paddr, .pwdata, .pready, .pslverr, .prdata,
    .awvalid(), .awready(1'b1), .awid(), .awaddr(), .awuser(), .awlen(),
    .awsize(), .awburst(), .wvalid(), .wready(1'b1), .wdata(), .wstrb(), .wlast(),
    .bvalid(1'b0), .bready(), .bresp(2'b00), .bid(4'h0),
    .arvalid, .arready, .arid, .araddr, .aruser(), .arlen, .arsize, .arburst,
    .rvalid, .rready, .rdata, .rresp, .rlast, .rid,
    .s_axis_pk_tvalid(1'b0), .s_axis_pk_tready(), .s_axis_pk_tdata('0),
    .s_axis_pk_tlast(1'b0),
    .m_axis_pk_tvalid(), .m_axis_pk_tready(1'b1), .m_axis_pk_tdata(), .m_axis_pk_tlast(),
    .irq(),
    .lv_tx_tvalid(), .lv_tx_tready('0), .lv_tx_tdata(),
    .lv_rx_tvalid('0), .lv_rx_tready(), .lv_rx_tdata('0),
    .lvcfg_din(), .lvcfg_din_vld(), .lvcfg_dout('0), .lvcfg_dout_vld('0),
    .spi_sclk(sclk_w), .spi_mosi(mosi_w), .spi_cs_n(cs_w), .spi_miso(miso_w),
    .chip_rst_n(), .clkctl(), .uart_rx(1'b1), .uart_tx()
  );

  // Chip SPI slave, AHB RAM and write monitor.
  logic [31:0] haddr, hwdata, hrdata;
  logic [1:0]  htrans;
  logic [2:0]  hsize, hburst;
  logic        hwrite, hready, hresp, hlock;
  logic [3:0]  hprot;
  logic        miso0;

  spi2ahb u_chip (
    .spi_cs_n(cs_w[0]), .spi_sck(sclk_w[0]), .spi_mosi(mosi_w[0]), .spi_miso(miso0),
    .hclk(chip_hclk), .hresetn(presetn),
    .hrdata(hrdata), .hready(hready), .hresp(hresp),
    .haddr(haddr), .hburst(hburst), .hmastlock(hlock), .hprot(hprot),
    .hsize(hsize), .htrans(htrans), .hwdata(hwdata), .hwrite(hwrite)
  );
  always_comb begin miso_w = '0; miso_w[0] = miso0; end

  logic [31:0] mem [0:65535];
  logic        ap_v, ap_w;
  logic [31:0] ap_a;
  assign hresp  = 1'b0;
  assign hready = 1'b1;
  assign hrdata = (ap_v && !ap_w) ? mem[ap_a[17:2]] : '0;
  always @(posedge chip_hclk or negedge presetn) begin
    if (!presetn) begin ap_v <= 0; ap_w <= 0; ap_a <= '0; end
    else begin
      if (ap_v && ap_w) mem[ap_a[17:2]] <= hwdata;
      ap_v <= htrans[1]; ap_a <= haddr; ap_w <= hwrite;
    end
  end
  typedef struct { logic [31:0] a, d; } wr_t;
  wr_t wr_log[$];
  always @(posedge chip_hclk) if (presetn && ap_v && ap_w) begin
    wr_t w; w.a = ap_a; w.d = hwdata; wr_log.push_back(w);
  end

  // DDR model. Addresses with bit 40 set return a read error.
  logic [127:0] ddr [longint unsigned];
  typedef struct { logic [47:0] addr; logic [7:0] len; logic [3:0] id; } ar_t;
  ar_t arq[$];
  int ar_stall;
  bit hold_ddr;
  int unsigned read_requests = 0, read_completions = 0;
  always @(posedge maxi_clk) ar_stall <= $urandom_range(0, 9);
  assign arready = maxi_rstn && (ar_stall != 0);
  always @(posedge maxi_clk) if (arvalid && arready) begin
    ar_t a;
    chk(arsize === 3'd4 && arburst === 2'b01, "BOOT expects 16-byte AXI INCR beats");
    chk(arlen === 8'd3 && araddr[5:0] === 6'd0, "BOOT expects an aligned 4-beat read");
    a.addr = araddr;
    a.len = arlen;
    a.id = arid;
    arq.push_back(a);
    read_requests++;
  end
  always @(posedge maxi_clk) if (rvalid && rready && rlast) read_completions++;
  initial begin
    rvalid = 0; rdata = '0; rresp = 2'b00; rlast = 0; rid = '0;
    wait (maxi_rstn);
    forever begin
      @(posedge maxi_clk);
      if (arq.size() > 0 && !hold_ddr) begin
        automatic ar_t a = arq.pop_front();
        for (int b = 0; b <= a.len; b++) begin
          while ($urandom_range(0, 3) == 0) @(posedge maxi_clk);
          rvalid <= 1;
          rid    <= a.id;
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

  // Drive setup and enable on falling edges. Sample each completed transfer at the rising edge.
  task automatic apb_access(input bit write, input logic [15:0] a, input logic [31:0] w,
                            output logic [31:0] r);
    @(negedge pclk);
    psel <= 1; penable <= 0; pwrite <= write; paddr <= a; pwdata <= w;
    @(negedge pclk); penable <= 1;
    @(posedge pclk); while (pready === 1'b0) @(posedge pclk);
    chk(pready === 1'b1 && pslverr === 1'b0, $sformatf("APB response at %04x", a));
    r = prdata;
    psel <= 0; penable <= 0;
  endtask
  task automatic apb_wr(input [15:0] a, input [31:0] d);
    logic [31:0] unused;
    apb_access(1, a, d, unused);
  endtask
  task automatic apb_rd(input [15:0] a, output [31:0] d);
    apb_access(0, a, '0, d);
  endtask

  // Expected versus observed AHB writes.
  wr_t exp_q[$];
  task automatic exp_wr(input [31:0] a, input [31:0] d);
    wr_t w; w.a = a; w.d = d; exp_q.push_back(w);
  endtask
  task automatic check_log(input string tag);
    chk(wr_log.size() == exp_q.size(),
        $sformatf("%s: AHB 写笔数 %0d 预期 %0d", tag, wr_log.size(), exp_q.size()));
    for (int i = 0; i < wr_log.size() && i < exp_q.size(); i++) begin
      chk(wr_log[i].a === exp_q[i].a && wr_log[i].d === exp_q[i].d,
          $sformatf("%s: 第 %0d 笔 %08x=%08x 预期 %08x=%08x", tag, i,
                    wr_log[i].a, wr_log[i].d, exp_q[i].a, exp_q[i].d));
    end
    wr_log.delete(); exp_q.delete();
  endtask

  task automatic start_boot(input [1:0] kind, input longint unsigned src,
                            input [31:0] len, input [31:0] dst);
    apb_wr(A_B_CMD,   {23'h0, 5'h0, 2'h0, kind});   // DIE=0
    apb_wr(A_B_SRCLO, src[31:0]);
    apb_wr(A_B_SRCHI, {16'h0, src[47:32]});
    apb_wr(A_B_LEN,   len);
    apb_wr(A_B_DST,   dst);
    apb_wr(A_B_DB,    32'h1);
  endtask

  task automatic check_completion(input [3:0] exp_code, input string tag);
    logic [31:0] status;
    bit saw_busy;
    saw_busy = 0;
    for (int t = 0; t < 200000 * tscale; t++) begin
      apb_rd(A_B_STA, status);
      if (status[0] === 1'b1) saw_busy = 1;
      if (status[0] === 1'b0 && (saw_busy || (exp_code == 4'd3 && status[8]))) break;
    end
    if (exp_code != 4'd3) chk(saw_busy, {tag, ": BUSY never observed"});
    chk(status[0] === 1'b0 && status[8] === 1'b1,
        $sformatf("%s: expected DONE on first idle read, STA=%08x", tag, status));
    chk(status[9] === (exp_code != 0) && status[15:12] === exp_code,
        $sformatf("%s: expected error code %0d, STA=%08x", tag, exp_code, status));
    apb_wr(A_B_STA, 32'h0000_0300);
  endtask

  task automatic boot_run(input [1:0] kind, input longint unsigned src,
                          input [31:0] len, input [31:0] dst,
                          input [3:0] exp_code, input string tag, input int poll_phase = -1);
    int unsigned ar_before, frames_before;
    ar_before = read_requests;
    frames_before = spi_frames;
    start_boot(kind, src, len, dst);
    if (poll_phase >= 0) begin
      // Single-frame cases poll every two pclk cycles from the same CS release.
      wait (cs_w[0] === 1'b0);
      @(posedge cs_w[0]);
      repeat (poll_phase) @(posedge pclk);
    end
    check_completion(exp_code, tag);
    if (exp_code == 4'd3) begin
      chk(read_requests == ar_before && spi_frames == frames_before,
          {tag, ": rejected request issued AXI or SPI traffic"});
    end
  endtask

  task automatic check_abort_idle(input string tag);
    logic [31:0] status;
    for (int t = 0; t < 200000 * tscale; t++) begin
      apb_rd(A_B_STA, status);
      if (status[0] === 1'b0) break;
    end
    chk({status[0], status[9:8]} === 3'b000, $sformatf("%s: abort STA=%08x", tag, status));
  endtask

  // Generate the DDR image and its expected chip writes.
  localparam longint unsigned SRC0 = 64'h0000_4000_0000;
  task automatic prep_words(input longint unsigned src, input int nwords,
                            input [31:0] dst);
    logic [31:0]  w;
    logic [127:0] line;
    for (int i = 0; i < nwords; i += 4) begin
      line = '0;
      for (int j = 0; j < 4; j++)
        if (i + j < nwords) begin
          w = $urandom;
          line[j * 32 +: 32] = w;
          exp_wr(dst + 32'(i + j) * 4, w);
        end
      ddr[(src >> 4) + longint'(i / 4)] = line;
    end
  endtask
  task automatic prep_prim(input longint unsigned src, input int nwords,
                           input [31:0] dst);
    exp_wr(32'h0208000C, 32'h1);                    // CLK_SHIFT on
    prep_words(src, nwords, dst);
    exp_wr(32'h0208000C, 32'h0);                    // CLK_SHIFT off
  endtask
  task automatic prep_fw(input longint unsigned src, input int nwords,
                         input [31:0] dst);
    prep_words(src, nwords, dst);
  endtask

  // Hold one accepted read until the host has requested abort or observed BUSY.
  task automatic held_read(input bit prim, input bit cancel, input string tag);
    longint unsigned src;
    logic [31:0] dst, status;
    int unsigned ar_before, last_before, frames_before;
    src = SRC0 + 64'h7000;
    dst = prim ? 32'h0200_0000 : 32'h0100_8000;
    if (prim) prep_prim(src, 16, dst);
    else      prep_fw(src, 16, dst);
    if (cancel) begin
      exp_q.delete();
      if (prim) begin
        exp_wr(32'h0208_000C, 1);
        exp_wr(32'h0208_000C, 0);
      end
    end

    ar_before = read_requests;
    last_before = read_completions;
    frames_before = spi_frames;
    hold_ddr = 1;
    start_boot(prim ? 2'd1 : 2'd0, src, 32'd64, dst);
    wait (read_requests != ar_before);
    if (cancel) apb_wr(A_GLB_CTRL, 1);
    apb_rd(A_B_STA, status);
    chk({status[9:8], status[0]} === 3'b001, {tag, ": task must wait for DDR"});
    chk(read_completions == last_before && spi_idle === 1'b1 &&
        spi_frames == frames_before + int'(prim), {tag, ": unexpected activity before R"});

    hold_ddr = 0;
    if (cancel) check_abort_idle(tag);
    else        check_completion(4'd0, tag);
    chk(read_requests == ar_before + 1 && read_completions == last_before + 1,
        {tag, ": expected one accepted and drained read"});
    if (cancel)
      chk(spi_frames == frames_before + (prim ? 2 : 0), {tag, ": unexpected SPI frame"});
    check_log(tag);
  endtask

  logic [31:0] v;

  initial begin
    int spi_div;
    tj_cases_init("P1,P2,P3,P4,P5,P6,P7,P8,P9,P10,P11");
    psel = 0; penable = 0; pwrite = 0; paddr = '0; pwdata = '0;
    #200ns;
    @(negedge pclk);
    presetn <= 1; maxi_rstn <= 1;
    #200ns;
    spi_div = int'($ceil(10.0 / pclk_hp)) - 1;
    if (spi_div < 1) spi_div = 1;
    apb_wr(A_SPI_DIV, spi_div);
    $display("BOOT clocks: pclk_hp=%0.3f ns maxi_hp=%0.3f ns SPI DIV=%0d",
             pclk_hp, maxi_hp, spi_div);
    wr_log.delete();

    // ---------- P1 BOOT_PRIM 2 行(64B) ----------
    if (tj_run_case("P1")) begin
      prep_prim(SRC0, 16, 32'h0200_0000);
      boot_run(2'd1, SRC0, 32'd64, 32'h0200_0000, 4'd0, "P1");
      check_log("P1");
      apb_rd(A_IRQ_RAW, v);
      chk(v[8] && !v[29], "P1: RAW[8] 完成且 [29] 无错");
      apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
      $display("P1 done (%0d checks, %0d errs)", checks, errs);
    end

    // ---------- P2 BOOT_PRIM 3 行(96B,跨 64B 块界重取数) ----------
    if (tj_run_case("P2")) begin
      prep_prim(SRC0 + 64'h1000, 24, 32'h0200_0040);
      boot_run(2'd1, SRC0 + 64'h1000, 32'd96, 32'h0200_0040, 4'd0, "P2");
      check_log("P2");
      $display("P2 done (%0d checks, %0d errs)", checks, errs);
    end

    // ---------- P3 FW_LOAD 256B(4×WR16) ----------
    if (tj_run_case("P3")) begin
      prep_fw(SRC0 + 64'h2000, 64, 32'h0100_0000);
      boot_run(2'd0, SRC0 + 64'h2000, 32'd256, 32'h0100_0000, 4'd0, "P3");
      check_log("P3");
      $display("P3 done (%0d checks, %0d errs)", checks, errs);
    end

    // ---------- P4 长度非法 ----------
    if (tj_run_case("P4")) begin
      boot_run(2'd1, SRC0, 32'd0,   32'h0200_0000, 4'd3, "P4a(len=0)");
      boot_run(2'd1, SRC0, 32'd160, 32'h0200_0000, 4'd3, "P4b(prim>128)");
      boot_run(2'd0, SRC0, 32'd96,  32'h0100_0000, 4'd3, "P4c(fw 非64倍数)");
      chk(wr_log.size() == 0, "P4: 非法长度不产生任何 SPI 写");
      exp_q.delete();
      $display("P4 done (%0d checks, %0d errs)", checks, errs);
    end

    // P5: A failed DDR read reports its own IRQ and closes CLK_SHIFT.
    if (tj_run_case("P5")) begin
      apb_wr(A_IRQ_RAW, 32'h2000_0000);
      apb_rd(A_IRQ_RAW, v);
      chk(v[29] === 1'b0, "P5: BOOT error IRQ must start clear");
      boot_run(2'd1, 64'h100_0000_0000, 32'd64, 32'h0200_0000, 4'd2, "P5");
      exp_wr(32'h0208000C, 32'h1);
      exp_wr(32'h0208000C, 32'h0);                    // 仅开/关两笔,数据零笔
      check_log("P5");
      apb_rd(A_IRQ_RAW, v);
      chk(v[29] === 1'b1, "P5: DDR error must set the BOOT error IRQ");
      apb_wr(A_IRQ_RAW, 32'hFFFF_FFFF);
      $display("P5 done (%0d checks, %0d errs)", checks, errs);
    end

    // P6: Timeout during the first CLK_SHIFT write. Check status at both APB polling phases.
    if (tj_run_case("P6")) begin
      apb_wr(A_SPI_TMO, 32'd50);
      for (int phase = 0; phase < 2; phase++)
        boot_run(2'd1, SRC0, 32'd64, 32'h0200_0000, 4'd1, "P6", phase);
      apb_wr(A_SPI_TMO, 32'h000F_4240);
      repeat (400) @(posedge pclk);
      wr_log.delete();
      $display("P6 done (%0d checks, %0d errs)", checks, errs);
    end

    // P7: Abort within the first data frame. That word must finish before CLK_SHIFT closes.
    if (tj_run_case("P7")) begin
      prep_prim(SRC0 + 64'h4000, 32, 32'h0200_0000);
      exp_q = exp_q[0:1];  // Keep CLK_SHIFT=1 and the first data word.
      exp_wr(32'h0208_000C, 0);
      start_boot(2'd1, SRC0 + 64'h4000, 32'd128, 32'h0200_0000);
      wait (cs_w[0] === 1'b0);
      @(posedge cs_w[0]);
      @(negedge cs_w[0]);
      apb_wr(A_GLB_CTRL, 1);
      check_abort_idle("P7");
      check_log("P7");
      prep_prim(SRC0 + 64'h5000, 16, 32'h0200_0000);
      boot_run(2'd1, SRC0 + 64'h5000, 32'd64, 32'h0200_0000, 4'd0, "P7b");
      check_log("P7b");
      $display("P7 done (%0d checks, %0d errs)", checks, errs);
    end

    // P8: Issue the SPIWIN read while the first firmware frame owns the SPI group.
    if (tj_run_case("P8")) begin
      mem[(32'h0100_2000 & 32'h3_FFFF) >> 2] = 32'hA5A5_5A5A;  // 预置芯片侧读值(模型按 [17:2] 索引)
      apb_wr(A_WIN_EN, 32'h1);
      apb_wr(A_WIN_PAGE, 32'h0);
      apb_wr(A_WIN_OFFS, 32'h0000_1002);              // 页=0x01002xxx
      prep_fw(SRC0 + 64'h6000, 64, 32'h0100_4000);
      start_boot(2'd0, SRC0 + 64'h6000, 32'd256, 32'h0100_4000);
      wait (cs_w[0] === 1'b0);
      fork
        begin
          apb_rd(16'h4000, v);
          chk(v === 32'hA5A5_5A5A, $sformatf("P8: SPIWIN read = %08x", v));
        end
        begin
          do @(posedge chip_hclk); while (!(ap_v && !ap_w));
          chk(ap_a === 32'h0100_2000, "P8: wrong AHB read address");
          chk(wr_log.size() > 0 && wr_log.size() < 64 && wr_log.size() % 16 == 0,
              "P8: SPIWIN must read between firmware bursts");
        end
      join
      check_completion(4'd0, "P8");
      check_log("P8");
      $display("P8 done (%0d checks, %0d errs)", checks, errs);
    end

    // P9: Compare the same held read with and without SRST.
    if (tj_run_case("P9")) begin
      held_read(0, 0, "P9 firmware control");
      held_read(0, 1, "P9 firmware abort");
      held_read(1, 1, "P9 primitive abort");
    end

    // P10: Misaligned, out-of-range and last legal destinations.
    if (tj_run_case("P10")) begin
      boot_run(2'd0, SRC0, 64,  32'h0100_0020, 3, "P10 firmware alignment");
      boot_run(2'd0, SRC0, 128, 32'hFFFF_FFC0, 3, "P10 firmware wrap");
      boot_run(2'd1, SRC0, 32,  32'h0200_0010, 3, "P10 primitive alignment");
      boot_run(2'd1, SRC0, 32,  32'h01FF_FFE0, 3, "P10 below core memory");
      boot_run(2'd1, SRC0, 64,  32'h0207_FFE0, 3, "P10 beyond last row");
      prep_prim(SRC0, 8, 32'h0207_FFE0);
      boot_run(2'd1, SRC0, 32, 32'h0207_FFE0, 0, "P10 last row");
      check_log("P10 last row");
      for (int phase = 0; phase < 2; phase++) begin
        prep_fw(SRC0, 16, 32'hFFFF_FFC0);
        boot_run(2'd0, SRC0, 64, 32'hFFFF_FFC0, 0, "P10 last block", phase);
        check_log("P10 last block");
      end
    end

    // P11: Abort BOOT while a doorbell transaction holds the SPI group.
    if (tj_run_case("P11")) begin
      // Cases: firmware data, initial CLK_SHIFT write, and primitive data.
      // Slow SPI keeps the doorbell active until SRST is issued.
      apb_wr(A_SPI_DIV, 32'd15);
      for (int k = 0; k < 3; k++) begin
        automatic bit prim = (k != 0);
        automatic longint unsigned src = SRC0 + 64'hB000 + 64'(k) * 64'h1000;
        automatic logic [31:0] dbd = 32'h600D_0000 + 32'(k);
        prep_words(src, 16, prim ? 32'h0200_0000 : 32'h0100_C000);
        exp_q.delete();
        repeat (400) @(posedge pclk);
        wr_log.delete();
        apb_wr(A_SPI_STA,  32'h0000_0300);
        apb_wr(A_SPI_CMD,  32'h0);
        apb_wr(A_SPI_ADDR, 32'h0100_F000);
        apb_wr(A_SPI_WD,   dbd);
        apb_wr(A_B_CMD,    {23'h0, 5'h0, 2'h0, prim ? 2'd1 : 2'd0});
        apb_wr(A_B_SRCLO,  src[31:0]);
        apb_wr(A_B_SRCHI,  {16'h0, src[47:32]});
        apb_wr(A_B_LEN,    32'd64);
        apb_wr(A_B_DST,    prim ? 32'h0200_0000 : 32'h0100_C000);
        if (k == 2) begin
          // Complete CLK_SHIFT=1, then let the doorbell block the BOOT data command.
          apb_wr(A_B_DB,   32'h1);
          apb_wr(A_SPI_DB, 32'h1);
          repeat (3400) @(posedge pclk);
        end else begin
          // Start the doorbell first so the first BOOT command waits for the group.
          apb_wr(A_SPI_DB, 32'h1);
          apb_wr(A_B_DB,   32'h1);
          repeat (800) @(posedge pclk);
        end
        apb_rd(A_SPI_STA, v);
        chk(v[0], $sformatf("P11.%0d: doorbell is busy before SRST", k));
        apb_rd(A_B_STA, v);
        chk(v[0], $sformatf("P11.%0d: BOOT is busy before SRST", k));
        apb_wr(A_GLB_CTRL, 32'h1);
        v = 32'h1;
        for (int t = 0; t < 200000 * tscale && v[0]; t++) apb_rd(A_B_STA, v);
        chk(!v[0], $sformatf("P11.%0d: BOOT becomes idle after SRST", k));
        chk(!v[8], $sformatf("P11.%0d: SRST does not set BOOT DONE", k));
        v = 0;
        for (int t = 0; t < 200000 * tscale && !v[8]; t++) apb_rd(A_SPI_STA, v);
        chk(v[8] && !v[9], $sformatf("P11.%0d: doorbell completes without a timeout", k));
        // Allow any uncanceled command to reach the chip before checking the write log.
        repeat (3000) @(posedge pclk);
        if (k == 2) exp_wr(32'h0208000C, 32'h1);
        exp_wr(32'h0100_F000, dbd);
        if (k == 2) exp_wr(32'h0208000C, 32'h0);
        check_log($sformatf("P11.%0d(%s)", k,
                  k == 0 ? "FW: doorbell only" : k == 1 ? "PRIM clock-on: doorbell only" : "PRIM data: clock-on/doorbell/clock-off"));
      end
      // Restore normal timing and check that a new BOOT task completes.
      apb_wr(A_SPI_DIV, spi_div);
      apb_wr(A_SPI_STA, 32'h0000_0300);
      prep_prim(SRC0 + 64'hE000, 16, 32'h0200_0000);
      boot_run(2'd1, SRC0 + 64'hE000, 32'd64, 32'h0200_0000, 4'd0, "P11b");
      check_log("P11b");
      $display("P11 done (%0d checks, %0d errs)", checks, errs);
    end

    if (errs != 0 || checks == 0) $fatal(1, "BOOT TB FAIL (%0d/%0d)", errs, checks);
    $display("BOOT TB PASS (%0d checks)", checks);
    $finish;
  end

  initial begin
    #0;  // Wait for clock plusargs to be applied.
    tscale = int'(1.0 + (maxi_hp / 1.2) * (5.0 / pclk_hp));
    #(80.0e6 * tscale * 1ns);
    $fatal(1, "BOOT TB TIMEOUT");
  end

endmodule
