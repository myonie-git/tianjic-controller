// File        : tb_tj_bypass.sv
// Module      : tb_tj_bypass
// Description : Tests SPI framing, APB arbitration and error recovery.
//               Covers enabled and disabled bypass configurations.
`timescale 1ns/1ps

module tb_tj_bypass #(
  parameter bit ENABLE_BYPASS_SPI = 1'b1
);
  `include "tj_case_select.svh"

  localparam int unsigned APB_AW = 16;

  // Clock and reset (pclk = 200 MHz).
  logic pclk = 1'b0;
  always #2.5 pclk = ~pclk;
  logic presetn = 1'b0;

  // SPI master signals.
  logic sclk = 1'b0, mosi = 1'b0, ss_n = 1'b1;
  logic miso, miso_oe;
  real  sclk_hp = 25.0;          // SPI half-period in ns (20 MHz by default).

  // Upstream APB master signals.
  logic              u_psel = 0, u_penable = 0, u_pwrite = 0;
  logic [APB_AW-1:0] u_paddr = '0;
  logic [31:0]       u_pwdata = '0;
  logic              u_pready, u_pslverr;
  logic [31:0]       u_prdata;

  // Downstream APB signals.
  logic              d_psel, d_penable, d_pwrite;
  logic [APB_AW-1:0] d_paddr;
  logic [31:0]       d_pwdata;
  logic              d_pready, d_pslverr;
  logic [31:0]       d_prdata;

  tj_bypass_spi #(
    .APB_AW(APB_AW), .ENABLE_BYPASS_SPI(ENABLE_BYPASS_SPI)
  ) u_dut (
    .pclk, .presetn,
    .spi_sclk(sclk), .spi_mosi(mosi), .spi_ss_n(ss_n),
    .spi_miso(miso), .spi_miso_oe(miso_oe),
    .u_psel, .u_penable, .u_pwrite, .u_paddr, .u_pwdata,
    .u_pready, .u_pslverr, .u_prdata,
    .d_psel, .d_penable, .d_pwrite, .d_paddr, .d_pwdata,
    .d_pready, .d_pslverr, .d_prdata
  );

  // APB RAM model with configurable wait states and 0xEExx errors.
  logic [31:0] mem [logic [APB_AW-1:0]];
  int unsigned apb_n_access = 0;
  int unsigned wait_left = 0;
  int unsigned wait_max = 3;     // Maximum APB wait cycles.
  int unsigned wait_min = 0;
  logic        in_acc = 0;

  function automatic logic [31:0] mem_rd(input logic [APB_AW-1:0] a);
    return mem.exists(a) ? mem[a] : (32'hC0DE_0000 | 32'(a));
  endfunction

  always @(posedge pclk or negedge presetn)
    if (!presetn) begin
      d_pready  <= 1'b0;
      d_pslverr <= 1'b0;
      d_prdata  <= '0;
      in_acc    <= 1'b0;
    end else begin
      d_pready  <= 1'b0;
      d_pslverr <= 1'b0;
      if (d_psel && d_penable && !d_pready) begin
        if (!in_acc) begin
          in_acc    <= 1'b1;
          wait_left <= $urandom_range(wait_min, wait_max);
        end else if (wait_left != 0) begin
          wait_left <= wait_left - 1;
        end else begin
          in_acc    <= 1'b0;
          d_pready  <= 1'b1;
          apb_n_access++;
          if (d_paddr[15:8] == 8'hEE) begin
            d_pslverr <= 1'b1;
            d_prdata  <= 32'hBAD0_BAD0;
          end else if (d_pwrite) begin
            mem[d_paddr] <= d_pwdata;
          end else begin
            d_prdata <= mem_rd(d_paddr);
          end
        end
      end
    end

  // Test checks.
  int unsigned n_chk = 0, n_err = 0;
  bit p2_addrs [logic [APB_AW-1:0]];
  bit p8_addrs [logic [APB_AW-1:0]];
  bit p8_write_data [logic [31:0]];

  task automatic chk(input bit cond, input string msg);
    n_chk++;
    if (!cond) begin
      n_err++;
      $display("[%0t] FAIL: %s", $time, msg);
    end
  endtask

  // Expected memory contents.
  logic [31:0] mir [logic [APB_AW-1:0]];
  function automatic logic [31:0] mir_rd(input logic [APB_AW-1:0] a);
    return mir.exists(a) ? mir[a] : (32'hC0DE_0000 | 32'(a));
  endfunction

  // SPI master model (mode 0, MSB first).
  task automatic spi_open();
    ss_n = 1'b0;
    #(50.0);                       // Allow 10 pclk cycles before the first SPI edge.
  endtask

  task automatic spi_close();
    #(50.0);
    ss_n = 1'b1;
    mosi = 1'b0;
    #(100.0);                      // SS high time between frames.
  endtask

  task automatic spi_byte(input logic [7:0] tx, output logic [7:0] rx);
    for (int i = 7; i >= 0; i--) begin
      mosi = tx[i];
      #(sclk_hp);
      rx[i] = miso;                // Sample MISO at the rising edge.
      sclk = 1'b1;
      #(sclk_hp);
      sclk = 1'b0;
    end
  endtask

  // Write n words and check header responses.
  task automatic spi_write(input logic [31:0] addr, input int n,
                           input logic [31:0] data [], input bit strict = 1);
    logic [7:0] r;
    logic [7:0] cmd = {1'b0, (n > 1), 6'(n - 1)};
    spi_open();
    spi_byte(cmd, r);            chk(r == 8'hA5, $sformatf("wr alive got %02x", r));
    spi_byte(addr[31:24], r);    chk(r == cmd,   $sformatf("wr echo got %02x", r));
    spi_byte(addr[23:16], r);    if (strict) chk(r == 8'h00, "wr st a1");
    spi_byte(addr[15:8],  r);    if (strict) chk(r == 8'h00, "wr st a2");
    spi_byte(addr[7:0],   r);    if (strict) chk(r == 8'h00, "wr st a3");
    for (int w = 0; w < n; w++)
      for (int b = 3; b >= 0; b--)
        spi_byte(data[w][8*b +: 8], r);
    spi_close();
  endtask

  // Read n words after two turnaround bytes.
  task automatic spi_read(input logic [31:0] addr, input int n,
                          output logic [31:0] data [],
                          input bit strict = 1);
    logic [7:0] r;
    logic [7:0] cmd = {1'b1, (n > 1), 6'(n - 1)};
    data = new[n];
    spi_open();
    spi_byte(cmd, r);            chk(r == 8'hA5, $sformatf("rd alive got %02x", r));
    spi_byte(addr[31:24], r);    chk(r == cmd,   $sformatf("rd echo got %02x", r));
    spi_byte(addr[23:16], r);
    spi_byte(addr[15:8],  r);
    spi_byte(addr[7:0],   r);
    spi_byte(8'h00, r);          if (strict) chk(r == 8'h00, "rd turn1");
    spi_byte(8'h00, r);          if (strict) chk(r == 8'h00, "rd turn2");
    for (int w = 0; w < n; w++) begin
      for (int b = 3; b >= 0; b--) begin
        spi_byte(8'h00, r);
        data[w][8*b +: 8] = r;
      end
    end
    spi_close();
  endtask

  // Upstream APB master model.
  task automatic up_xfer(input bit wr, input logic [APB_AW-1:0] a,
                         input logic [31:0] wd, output logic [31:0] rd,
                         output bit slverr);
    @(posedge pclk);
    u_psel   <= 1'b1;
    u_pwrite <= wr;
    u_paddr  <= a;
    u_pwdata <= wd;
    @(posedge pclk);
    u_penable <= 1'b1;
    do @(posedge pclk); while (!u_pready);
    rd     = u_prdata;
    slverr = u_pslverr;
    u_psel    <= 1'b0;
    u_penable <= 1'b0;
    repeat ($urandom_range(0, 3)) @(posedge pclk);
  endtask

  // Hold PSEL high and lower PENABLE for each new setup phase.
  task automatic up_b2b_wr(input int n, input logic [APB_AW-1:0] base);
    int unsigned guard;
    @(posedge pclk);
    u_psel   <= 1'b1;
    u_pwrite <= 1'b1;
    for (int i = 0; i < n; i++) begin
      u_paddr   <= base + 16'(4 * i);
      u_pwdata  <= 32'hB2B0_0000 + 32'(i);
      u_penable <= 1'b0;
      @(posedge pclk);                    // APB setup phase.
      u_penable <= 1'b1;
      guard = 0;
      do begin
        @(posedge pclk);
        guard++;
      end while (!u_pready && guard < 300);
      chk(guard < 300, $sformatf("P12 b2b xfer%0d hang(psel 保持型死锁)", i));
      if (guard >= 300) break;
      mir[base + 16'(4 * i)] = 32'hB2B0_0000 + 32'(i);
    end
    u_psel    <= 1'b0;
    u_penable <= 1'b0;
    @(posedge pclk);
  endtask

  // Check reset and deselection after combinational outputs settle.
  always @(negedge pclk) begin
    #1ps;
    if (!ENABLE_BYPASS_SPI || !presetn || ss_n)
      chk(miso_oe === 1'b0, "MISO released while disabled, reset or deselected");
  end

  task automatic check_disabled();
    logic [31:0] data;
    logic [7:0] byte_read;
    bit err;
    int unsigned start_access;
    start_access = apb_n_access;
    fork
      begin
        ss_n = 1'b0;
        #50;
        spi_byte(8'h00, byte_read);
        spi_byte(8'h00, byte_read);
        spi_byte(8'h00, byte_read);
        spi_byte(8'h01, byte_read);
        spi_byte(8'h00, byte_read);
        repeat (4) spi_byte(8'hA5, byte_read);
        spi_close();
      end
      begin
        for (int i = 0; i < 16; i++) begin
          up_xfer(1'b1, 16'h1000 + 16'(4*i), 32'hCAFE_0000 + 32'(i), data, err);
          chk(!err, "Disabled bypass forwards APB write");
          up_xfer(1'b0, 16'h1000 + 16'(4*i), '0, data, err);
          chk(!err && data === 32'hCAFE_0000 + 32'(i),
              "Disabled bypass forwards APB read data");
        end
      end
    join
    chk(apb_n_access == start_access + 32,
        "Disabled SPI generates no downstream APB transactions");

    up_b2b_wr(8, 16'h2000);
    for (int i = 0; i < 8; i++) begin
      up_xfer(1'b0, 16'h2000 + 16'(4*i), '0, data, err);
      chk(!err && data === 32'hB2B0_0000 + 32'(i),
          "Disabled bypass supports back-to-back APB writes");
    end
    up_xfer(1'b0, 16'hEE00, '0, data, err);
    chk(err && data === 32'hBAD0_BAD0, "Disabled bypass forwards APB read errors");
    up_xfer(1'b1, 16'hEE00, 32'h1234_5678, data, err);
    chk(err, "Disabled bypass forwards APB write errors");
  endtask

  // Main test sequence.
  logic [31:0] wbuf [];
  logic [31:0] rbuf [];
  logic [7:0]  r8;
  int unsigned base_n;

  initial begin : main
    tj_cases_init(ENABLE_BYPASS_SPI ? "P1,P2,P3,P4,P5,P6,P7,P8,P9,P10,P11,P12,P13,P14,P15,P16,P17" : "DISABLED");
    $timeformat(-9, 1, "ns", 10);
    presetn = 1'b0;
    repeat (10) @(posedge pclk);
    presetn = 1'b1;
    repeat (10) @(posedge pclk);

    if (!ENABLE_BYPASS_SPI) begin
      if (tj_run_case("DISABLED")) check_disabled();
      if (n_err == 0) $display("BYPASS TB PASS (%0d checks)", n_chk);
      else $fatal(1, "BYPASS TB FAIL (%0d errors/%0d checks)", n_err, n_chk);
      $finish;
    end

    // P10a: Deselected MISO output enable.
    if (tj_case_wanted("P10")) chk(miso_oe == 1'b0, "P10 oe idle");

    // P1: SPI response and single-word write/read.
    if (tj_run_case("P1")) begin
      $display("== P1 活性/单字回环");
      wbuf = new[1]; wbuf[0] = 32'h1234_ABCD;
      spi_write(32'h0000_0100, 1, wbuf); mir[16'h0100] = 32'h1234_ABCD;
      spi_read (32'h0000_0100, 1, rbuf);
      chk(rbuf[0] == 32'h1234_ABCD, $sformatf("P1 rb got %08x", rbuf[0]));
    end

    // P2: Random single-word accesses.
    if (tj_run_case("P2")) begin
      $display("== P2 随机单字 x200");
      for (int i = 0; i < 200; i++) begin
        logic [APB_AW-1:0] a;
        a = {$urandom_range(0, 16'hDFFF)} & 16'hFFFC;
        if (a[15:8] == 8'hEE) a[15:8] = 8'h11;
        p2_addrs[a] = 1'b1;
        if ($urandom_range(0, 1)) begin
          wbuf = new[1]; wbuf[0] = $urandom();
          spi_write({16'h0, a}, 1, wbuf); mir[a] = wbuf[0];
        end else begin
          spi_read({16'h0, a}, 1, rbuf);
          chk(rbuf[0] == mir_rd(a), $sformatf("P2 rd @%04x got %08x exp %08x", a, rbuf[0], mir_rd(a)));
        end
      end
    end

    // P3: 64-word incrementing burst.
    if (tj_run_case("P3")) begin
      $display("== P3 64 字突发");
      wbuf = new[64];
      for (int i = 0; i < 64; i++) begin
        wbuf[i] = $urandom();
        mir[16'h2000 + 16'(4*i)] = wbuf[i];
      end
      spi_write(32'h0000_2000, 64, wbuf);
      spi_read (32'h0000_2000, 64, rbuf);
      for (int i = 0; i < 64; i++)
        chk(rbuf[i] == wbuf[i], $sformatf("P3 word%0d got %08x exp %08x", i, rbuf[i], wbuf[i]));
    end

    // P4: Reject multiword transfers without address increment.
    if (tj_run_case("P4")) begin
      $display("== P4 非自增多字拒绝");
      base_n = apb_n_access;
      spi_open();
      spi_byte(8'h01, r8);  chk(r8 == 8'hA5, "P4 alive");     // Write two words without address increment.
      spi_byte(8'h00, r8);  chk(r8 == 8'h01, "P4 echo");
      spi_byte(8'h00, r8);  chk(r8 == 8'hEE, "P4 rej a1");
      spi_byte(8'h01, r8);  chk(r8 == 8'hEE, "P4 rej a2");
      spi_byte(8'h00, r8);  chk(r8 == 8'hEE, "P4 rej a3");
      spi_byte(8'hAA, r8);  chk(r8 == 8'hEE, "P4 rej d0");
      spi_close();
      chk(apb_n_access == base_n, "P4 zero apb access");
    end

    // P5: Reject addresses above the APB window.
    if (tj_run_case("P5")) begin
      $display("== P5 高位越界拒绝");
      base_n = apb_n_access;
      spi_open();
      spi_byte(8'h00, r8);  chk(r8 == 8'hA5, "P5 alive");     // Single-word write.
      spi_byte(8'h00, r8);  chk(r8 == 8'h00, "P5 echo");
      spi_byte(8'h01, r8);                                     // Address 0x00010000.
      spi_byte(8'h00, r8);
      spi_byte(8'h00, r8);  chk(r8 == 8'h00, "P5 st a3(拒绝在下一字节可见)");
      spi_byte(8'h55, r8);  chk(r8 == 8'hEE, "P5 rej d0");
      spi_byte(8'h55, r8);  chk(r8 == 8'hEE, "P5 rej d1");
      spi_close();
      chk(apb_n_access == base_n, "P5 zero apb access");
    end

    // P6: Abort a frame by releasing SS.
    if (tj_run_case("P6")) begin
      $display("== P6 SS 中途拔起");
      spi_open();
      spi_byte(8'h43, r8);                                     // Write four words with address increment.
      spi_byte(8'h00, r8); spi_byte(8'h00, r8);
      spi_byte(8'h30, r8); spi_byte(8'h00, r8);                // Address 0x3000.
      for (int b = 3; b >= 0; b--) spi_byte(8'(8'h10 + b), r8); // First word: 0x13121110.
      for (int b = 3; b >= 0; b--) spi_byte(8'(8'h20 + b), r8); // Second word.
      spi_byte(8'h77, r8); spi_byte(8'h66, r8);                // Partial third word.
      spi_close();
      mir[16'h3000] = 32'h1312_1110;
      mir[16'h3004] = 32'h2322_2120;
      spi_read(32'h0000_3000, 1, rbuf);
      chk(rbuf[0] == 32'h1312_1110, "P6 w0 committed");
      spi_read(32'h0000_3004, 1, rbuf);
      chk(rbuf[0] == 32'h2322_2120, "P6 w1 committed");
      spi_read(32'h0000_3008, 1, rbuf);
      chk(rbuf[0] == mem_rd(16'h3008) && !mem.exists(16'h3008), "P6 w2 not committed");
    end

    // P7: Transfer beyond the declared length.
    if (tj_run_case("P7")) begin
      $display("== P7 超 LEN");
      base_n = apb_n_access;
      spi_open();
      spi_byte(8'h40, r8);                                     // Write one word with address increment.
      spi_byte(8'h00, r8); spi_byte(8'h00, r8);
      spi_byte(8'h40, r8); spi_byte(8'h00, r8);                // Address 0x4000.
      for (int b = 3; b >= 0; b--) spi_byte(8'(8'hA0 + b), r8); // Declared data word.
      for (int b = 3; b >= 0; b--) spi_byte(8'hFF, r8);        // Extra data word.
      spi_byte(8'h00, r8);                                     // Clock another byte to read the error status.
      chk(r8 == 8'hEE, "P7 wr overrun st");
      spi_close();
      mir[16'h4000] = 32'hA3A2_A1A0;
      chk(!mem.exists(16'h4004), "P7 extra word dropped");
      // Read one extra byte after a single-word transfer.
      spi_open();
      spi_byte(8'hC0, r8);                                     // Read one word with address increment.
      spi_byte(8'h00, r8); spi_byte(8'h00, r8);
      spi_byte(8'h40, r8); spi_byte(8'h00, r8);
      spi_byte(8'h00, r8); spi_byte(8'h00, r8);                // turnaround
      for (int b = 0; b < 4; b++) spi_byte(8'h00, r8);
      spi_byte(8'h00, r8);
      chk(r8 == 8'hEE, "P7 rd overrun st");
      spi_close();
    end

    // P8: Concurrent upstream APB and SPI traffic.
    if (tj_run_case("P8")) begin
      $display("== P8 上游并发");
      fork
        begin : up_traffic
          logic [31:0] rd; bit sl;
          for (int i = 0; i < 100; i++) begin
            logic [APB_AW-1:0] a;
            a = 16'h5000 + 16'(4 * $urandom_range(0, 63));
            p8_addrs[a] = 1'b1;
            if ($urandom_range(0, 1)) begin
              logic [31:0] d;
              d = $urandom();
              p8_write_data[d] = 1'b1;
              up_xfer(1'b1, a, d, rd, sl);
              mir[a] = d;
              chk(!sl, "P8 up wr slverr");
            end else begin
              up_xfer(1'b0, a, 32'h0, rd, sl);
              chk(rd == mir_rd(a), $sformatf("P8 up rd @%04x got %08x exp %08x", a, rd, mir_rd(a)));
              chk(!sl, "P8 up rd slverr");
            end
          end
        end
        begin : spi_traffic
          wbuf = new[32];
          for (int i = 0; i < 32; i++) begin
            wbuf[i] = $urandom();
            mir[16'h6000 + 16'(4*i)] = wbuf[i];
          end
          spi_write(32'h0000_6000, 32, wbuf);
          spi_read (32'h0000_6000, 32, rbuf);
          for (int i = 0; i < 32; i++)
            chk(rbuf[i] == wbuf[i], $sformatf("P8 spi word%0d", i));
        end
      join
    end

    // P9: Sticky APB error and recovery on the next frame.
    if (tj_run_case("P9")) begin
      $display("== P9 pslverr");
      wbuf = new[2]; wbuf[0] = 32'h1; wbuf[1] = 32'h2;
      spi_open();
      spi_byte(8'h41, r8);                                     // Write two words with address increment.
      spi_byte(8'h00, r8); spi_byte(8'h00, r8);
      spi_byte(8'hEE, r8); spi_byte(8'h00, r8);                // Address 0xEE00 returns an APB error.
      for (int b = 3; b >= 0; b--) spi_byte(8'h11, r8);
      for (int b = 3; b >= 0; b--) spi_byte(8'h22, r8);
      chk(r8 == 8'hEE, "P9 slverr sticky");
      spi_close();
      spi_read(32'h0000_0100, 1, rbuf);                        // Read a valid address in a new frame.
      chk(rbuf[0] == mir_rd(16'h0100), "P9 next frame clean");
    end

    // P10b: MISO output enable during a frame.
    if (tj_run_case("P10")) begin
      spi_open();
      spi_byte(8'h00, r8);
      chk(miso_oe == 1'b1, "P10 oe active");
      spi_close();
      chk(miso_oe == 1'b0, "P10 oe released");
    end

    // P11: Maximum SPI clock rate (SCLK = pclk/8).
    if (tj_run_case("P11")) begin
      $display("== P11 SCLK=pclk/8 边界");
      sclk_hp = 20.0;                                          // 25 MHz with pclk = 200 MHz.
      wbuf = new[8];
      for (int i = 0; i < 8; i++) begin
        wbuf[i] = $urandom();
        mir[16'h7000 + 16'(4*i)] = wbuf[i];
      end
      spi_write(32'h0000_7000, 8, wbuf);
      spi_read (32'h0000_7000, 8, rbuf);
      for (int i = 0; i < 8; i++)
        chk(rbuf[i] == wbuf[i], $sformatf("P11 word%0d got %08x exp %08x", i, rbuf[i], wbuf[i]));
    end

    // P12: Back-to-back upstream APB transfers.
    if (tj_run_case("P12")) begin
      if (tj_case_filter_active) sclk_hp = 20.0;
      $display("== P12 上游 back-to-back");
      up_b2b_wr(8, 16'h0800);
      spi_read(32'h0000_0800, 8, rbuf);
      for (int i = 0; i < 8; i++)
        chk(rbuf[i] == 32'hB2B0_0000 + 32'(i), $sformatf("P12 word%0d got %08x", i, rbuf[i]));
    end

    // P13: Late APB responses after a frame is aborted.
    if (tj_run_case("P13")) begin
      if (tj_case_filter_active) sclk_hp = 20.0;
      $display("== P13 帧中止跨帧响应");
      wbuf = new[1];
      wbuf[0] = 32'hAAAA_0001; spi_write(32'h0000_9000, 1, wbuf); mir[16'h9000] = wbuf[0];
      wbuf[0] = 32'hBBBB_0002; spi_write(32'h0000_9100, 1, wbuf); mir[16'h9100] = wbuf[0];
      // Abort a delayed read, then start a new read frame.
      wait_max = 40;
      ss_n = 1'b0; #(50.0);
      spi_byte(8'hC1, r8);                                     // Read two words from 0x9000.
      spi_byte(8'h00, r8); spi_byte(8'h00, r8);
      spi_byte(8'h90, r8); spi_byte(8'h00, r8);
      #(30.0); ss_n = 1'b1; mosi = 1'b0;
      #(40.0);                                                 // Minimum SS high time: 8 pclk cycles.
      wait_max = 3;
      spi_read(32'h0000_9100, 1, rbuf);                        // Check data from the new frame.
      chk(rbuf[0] == 32'hBBBB_0002, $sformatf("P13A cross-frame stale data got %08x", rbuf[0]));
      // Abort a write with a delayed APB error, then start a valid frame.
      wait_max = 40;
      ss_n = 1'b0; #(50.0);
      spi_byte(8'h40, r8);                                     // Write one word to 0xEE00.
      spi_byte(8'h00, r8); spi_byte(8'h00, r8);
      spi_byte(8'hEE, r8); spi_byte(8'h00, r8);
      for (int b = 3; b >= 0; b--) spi_byte(8'h5A, r8);
      #(30.0); ss_n = 1'b1; mosi = 1'b0;
      #(40.0);
      wait_max = 3;
      spi_read(32'h0000_9000, 1, rbuf);                        // Check the turnaround status.
      chk(rbuf[0] == 32'hAAAA_0001, "P13B after cross-frame slverr");
    end

    // Slow writes stop at the first dropped word instead of shifting later data.
    if (tj_run_case("P14")) begin
      if (tj_case_filter_active) sclk_hp = 20.0;
      begin
        logic [31:0] saved [6];
        wait_min = 320;
        wait_max = 320;
        wbuf = new[6];
        for (int i = 0; i < 6; i++) begin
          saved[i] = mem_rd(16'hA000 + 16'(4*i));
          wbuf[i] = 32'h5100_0000 + 32'(i);
        end
        base_n = apb_n_access;
        spi_write(32'h0000_A000, 6, wbuf);
        repeat (500) @(posedge pclk);
        chk(apb_n_access == base_n + 1, "Slow write stops after the outstanding word");
        chk(mem_rd(16'hA000) === wbuf[0], "Slow write commits the accepted word");
        for (int i = 1; i < 6; i++)
          chk(mem_rd(16'hA000 + 16'(4*i)) === saved[i],
              "Slow write leaves later addresses untouched");
      end
    end

    // A read underrun stops further prefetch requests.
    if (tj_run_case("P15")) begin
      if (tj_case_filter_active) sclk_hp = 20.0;
      wait_min = 400;
      wait_max = 400;
      base_n = apb_n_access;
      spi_read(32'h0000_B000, 8, rbuf, 1'b0);
      repeat (500) @(posedge pclk);
      chk(apb_n_access == base_n + 1, "Read underrun stops prefetch");
      foreach (rbuf[i])
        chk(rbuf[i] === 32'hEEEE_EEEE, "Read underrun returns sticky error bytes");
    end

    // An APB error terminates further reads or writes in the frame.
    if (tj_run_case("P16")) begin
      if (tj_case_filter_active) sclk_hp = 20.0;
      wait_min = 0;
      wait_max = 3;
      base_n = apb_n_access;
      spi_read(32'h0000_EE00, 4, rbuf, 1'b0);
      chk(apb_n_access == base_n + 1, "APB read error stops prefetch");
      foreach (rbuf[i])
        chk(rbuf[i] === 32'hEEEE_EEEE, "APB read error remains visible");
      base_n = apb_n_access;
      wbuf = new[4];
      foreach (wbuf[i]) wbuf[i] = 32'h5200_0000 + 32'(i);
      spi_write(32'h0000_EE00, 4, wbuf);
      chk(apb_n_access == base_n + 1, "APB write error stops later writes");
      spi_read(32'h0000_0100, 1, rbuf);
      chk(rbuf[0] === mem_rd(16'h0100), "A fresh frame recovers after an APB error");
    end

    // Pause SCLK with SS low when accessing a slow target.
    if (tj_run_case("P17")) begin
      if (tj_case_filter_active) sclk_hp = 20.0;
      wait_min = 400;
      wait_max = 400;
      spi_open();
      spi_byte(8'h80, r8);
      spi_byte(8'h00, r8);
      spi_byte(8'h00, r8);
      spi_byte(8'h01, r8);
      spi_byte(8'h00, r8);
      repeat (500) @(posedge pclk);
      spi_byte(8'h00, r8);
      chk(r8 == 8'h00, "Paused read first turnaround status");
      spi_byte(8'h00, r8);
      chk(r8 == 8'h00, "Paused read second turnaround status");
      rbuf = new[1];
      for (int b = 3; b >= 0; b--)
        spi_byte(8'h00, rbuf[0][8*b +: 8]);
      spi_close();
      chk(rbuf[0] === mem_rd(16'h0100), "Paused read returns the complete word");

      for (int target = 0; target < 2; target++) begin
        logic [31:0] addr;
        addr = target == 0 ? 32'h0000_F000 : 32'h0000_EE00;
        spi_open();
        spi_byte(8'h00, r8);
        for (int b = 3; b >= 0; b--) spi_byte(addr[8*b +: 8], r8);
        repeat (4) spi_byte(8'h5A, r8);
        repeat (500) @(posedge pclk);
        spi_byte(8'h00, r8);
        spi_byte(8'h00, r8);
        chk(r8 == (target == 0 ? 8'h00 : 8'hEE),
            "Paused write reports its result in the second status byte");
        spi_close();
      end
      chk(mem_rd(16'hF000) === 32'h5A5A_5A5A, "Paused write reaches the target");
      wait_min = 0;
      wait_max = 3;
      spi_read(32'h0000_F000, 1, rbuf);
      chk(rbuf[0] === 32'h5A5A_5A5A, "A fresh frame recovers after a paused error");
    end

    if (tj_case_wanted("P2")) chk(p2_addrs.num() > 1, "P2 generates multiple addresses");
    if (tj_case_wanted("P8")) chk(p8_addrs.num() > 1, "P8 generates multiple addresses");
    if (tj_case_wanted("P8")) chk(p8_write_data.num() > 1, "P8 generates multiple write values");
    $display("BYPASS COVERAGE: P2 addresses=%0d P8 addresses=%0d P8 write data=%0d",
             p2_addrs.num(), p8_addrs.num(), p8_write_data.num());

    // Report the test result.
    if (n_err == 0) $display("BYPASS TB PASS (%0d checks)", n_chk);
    else            $display("BYPASS TB FAIL(%0d 错/%0d 项)", n_err, n_chk);
    $finish;
  end

  // Simulation timeout.
  initial begin
    #8_000_000;
    $display("BYPASS TB FAIL(全局超时)");
    $finish;
  end

endmodule
