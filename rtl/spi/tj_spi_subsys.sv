// File        : tj_spi_subsys.sv
// Module      : tj_spi_subsys
// Description : Eight SPI groups shared by CSR doorbells, SPIWIN and BOOT.
//               Four dies per group; pclk domain, active-low asynchronous reset.

// CSR-controlled single-word SPI transactions.
module tj_spi_doorbell (
  input  logic        clk,
  input  logic        rst_n,
  // CSR interface (pclk domain).
  input  logic        db_go,        // Ignored while busy.
  input  logic [1:0]  csr_kind,      // 0: write; 1: read; 2/3: no-op.
  input  logic [1:0]  csr_die,
  input  logic [31:0] csr_addr,
  input  logic [31:0] csr_wdata,
  input  logic [2:0]  grp_id,        // SPI group index (0..7).
  output logic [31:0] rdata_o,
  output logic        busy_o,
  output logic        done_set_o,
  output logic        err_set_o,
  // SPI transaction interface (arbiter B port).
  output logic        cmd_valid,
  input  logic        cmd_ready,
  output logic [4:0]  die_id,
  output logic [1:0]  cmd_kind,
  output logic [31:0] addr,
  output logic        wdat_valid,
  input  logic        wdat_ready,
  output logic [31:0] wdat,
  input  logic        rdat_valid,
  output logic        rdat_ready,
  input  logic [31:0] rdat,
  input  logic        done,
  input  logic        err_timeout
);
  typedef enum logic [1:0] {D_IDLE, D_CMD, D_WAIT} st_e;
  st_e st_q;
  logic is_rd_q, need_w_q;

  assign rdat_ready = 1'b1;
  // Keep BUSY set until the CSR latches the terminal event.
  assign busy_o     = (st_q != D_IDLE) || done_set_o || err_set_o;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q       <= D_IDLE;
      cmd_valid  <= 1'b0;
      wdat_valid <= 1'b0;
      die_id     <= '0;
      cmd_kind   <= '0;
      addr       <= '0;
      wdat       <= '0;
      rdata_o    <= '0;
      done_set_o <= 1'b0;
      err_set_o  <= 1'b0;
      is_rd_q    <= 1'b0;
      need_w_q   <= 1'b0;
    end else begin
      // One-cycle event pulses to the CSR.
      done_set_o <= 1'b0;
      err_set_o  <= 1'b0;
      unique case (st_q)
        D_IDLE: if (db_go && !busy_o) begin
          if (csr_kind[1]) begin
            // Reserved kinds complete without issuing a transaction.
            done_set_o <= 1'b1;
          end else begin
            is_rd_q   <= csr_kind[0];
            need_w_q  <= !csr_kind[0];
            cmd_kind  <= csr_kind[0] ? 2'd2 : 2'd0; // Engine encoding: 0=WR1, 2=RD1.
            die_id    <= {grp_id, csr_die};
            addr      <= csr_addr;
            wdat      <= csr_wdata;
            cmd_valid <= 1'b1;
            st_q      <= D_CMD;
          end
        end

        D_CMD: begin
          if (cmd_ready && cmd_valid) begin
            cmd_valid  <= 1'b0;
            wdat_valid <= need_w_q;
            st_q       <= D_WAIT;
          end
        end

        D_WAIT: begin
          if (wdat_valid && wdat_ready)
            wdat_valid <= 1'b0;
          if (rdat_valid && is_rd_q)
            rdata_o <= rdat;

          if (done) begin
            done_set_o <= 1'b1;
            st_q       <= D_IDLE;
          end
          if (err_timeout) begin
            err_set_o  <= 1'b1;
            wdat_valid <= 1'b0;
            st_q       <= D_IDLE;
          end
        end
        default:
          st_q <= D_IDLE;
      endcase
    end
  end
endmodule

// Two-source SPI arbiter; A has priority when idle.
module tj_spi_arb2 (
  input  logic        clk,
  input  logic        rst_n,
  // SPIWIN (A).
  input  logic        a_cmd_valid,
  output logic        a_cmd_ready,
  input  logic [4:0]  a_die,
  input  logic [1:0]  a_kind,
  input  logic [31:0] a_addr,
  input  logic        a_wdat_valid,
  output logic        a_wdat_ready,
  input  logic [31:0] a_wdat,
  output logic        a_rdat_valid,
  input  logic        a_rdat_ready,
  output logic        a_done,
  output logic        a_err,
  // Doorbell (B).
  input  logic        b_cmd_valid,
  output logic        b_cmd_ready,
  input  logic [4:0]  b_die,
  input  logic [1:0]  b_kind,
  input  logic [31:0] b_addr,
  input  logic        b_wdat_valid,
  output logic        b_wdat_ready,
  input  logic [31:0] b_wdat,
  output logic        b_rdat_valid,
  input  logic        b_rdat_ready,
  output logic        b_done,
  output logic        b_err,
  // SPI engine.
  output logic        e_cmd_valid,
  input  logic        e_cmd_ready,
  output logic [4:0]  e_die,
  output logic [1:0]  e_kind,
  output logic [31:0] e_addr,
  output logic        e_wdat_valid,
  input  logic        e_wdat_ready,
  output logic [31:0] e_wdat,
  input  logic        e_rdat_valid,
  output logic        e_rdat_ready,
  input  logic [31:0] e_rdat,
  input  logic        e_done,
  input  logic        e_err,
  output logic [31:0] rdat_bus       // Shared read data; valid is gated per source.
);
  typedef enum logic [1:0] {G_NONE, G_A, G_B} g_e;
  g_e g_q;

  // Select a source while idle; otherwise keep the current owner.
  wire pick_a = (g_q == G_NONE) ? a_cmd_valid : (g_q == G_A);
  wire pick_b = (g_q == G_NONE) ? (!a_cmd_valid && b_cmd_valid) : (g_q == G_B);

  assign e_cmd_valid  = pick_a ? a_cmd_valid  : pick_b ? b_cmd_valid  : 1'b0;
  assign e_die        = pick_a ? a_die        : b_die;
  assign e_kind       = pick_a ? a_kind       : b_kind;
  assign e_addr       = pick_a ? a_addr       : b_addr;
  assign e_wdat_valid = pick_a ? a_wdat_valid : pick_b ? b_wdat_valid : 1'b0;
  assign e_wdat       = pick_a ? a_wdat       : b_wdat;
  assign e_rdat_ready = pick_a ? a_rdat_ready : pick_b ? b_rdat_ready : 1'b1;

  assign a_cmd_ready  = pick_a && e_cmd_ready;
  assign b_cmd_ready  = pick_b && e_cmd_ready;
  assign a_wdat_ready = pick_a && e_wdat_ready;
  assign b_wdat_ready = pick_b && e_wdat_ready;
  assign a_rdat_valid = pick_a && e_rdat_valid;
  assign b_rdat_valid = pick_b && e_rdat_valid;
  assign a_done = pick_a && e_done;
  assign b_done = pick_b && e_done;
  assign a_err  = pick_a && e_err;
  assign b_err  = pick_b && e_err;
  assign rdat_bus = e_rdat;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) g_q <= G_NONE;
    else begin
      if (g_q == G_NONE) begin
        if (e_cmd_valid && e_cmd_ready) g_q <= pick_a ? G_A : G_B;
      end else if (e_done || e_err) begin
        if (!(e_cmd_valid && e_cmd_ready))
          g_q <= G_NONE;
      end
    end
  end
endmodule

// -----------------------------------------------------------------------------
// 全局主 2:1 仲裁(批次 BOOT):A=SPIWIN(host 交互,高优先) B=BOOT 引擎
// 授权按事务保持(cmd 接受 → done/err);合流后走既有组 demux,组内零改动
// -----------------------------------------------------------------------------
module tj_spi_gmux (
  input  logic        clk,
  input  logic        rst_n,
  // A 口(SPIWIN)
  input  logic        a_cmd_valid,
  output logic        a_cmd_ready,
  input  logic [4:0]  a_die,
  input  logic [1:0]  a_kind,
  input  logic [31:0] a_addr,
  input  logic        a_wdat_valid,
  output logic        a_wdat_ready,
  input  logic [31:0] a_wdat,
  output logic        a_rdat_valid,
  input  logic        a_rdat_ready,
  output logic        a_done,
  output logic        a_err,
  // B 口(BOOT)
  input  logic        b_cmd_valid,
  output logic        b_cmd_ready,
  input  logic [4:0]  b_die,
  input  logic [1:0]  b_kind,
  input  logic [31:0] b_addr,
  input  logic        b_wdat_valid,
  output logic        b_wdat_ready,
  input  logic [31:0] b_wdat,
  output logic        b_rdat_valid,
  input  logic        b_rdat_ready,
  output logic        b_done,
  output logic        b_err,
  // 合流主口(接组 demux)
  output logic        m_cmd_valid,
  input  logic        m_cmd_ready,
  output logic [4:0]  m_die,
  output logic [1:0]  m_kind,
  output logic [31:0] m_addr,
  output logic        m_wdat_valid,
  input  logic        m_wdat_ready,
  output logic [31:0] m_wdat,
  input  logic        m_rdat_valid,
  output logic        m_rdat_ready,
  input  logic        m_done,
  input  logic        m_err
);
  typedef enum logic [1:0] {M_NONE, M_A, M_B} g_e;
  g_e g_q;
  wire pick_a = (g_q == M_NONE) ? a_cmd_valid : (g_q == M_A);
  wire pick_b = (g_q == M_NONE) ? (!a_cmd_valid && b_cmd_valid) : (g_q == M_B);

  assign m_cmd_valid  = pick_a ? a_cmd_valid  : pick_b ? b_cmd_valid  : 1'b0;
  assign m_die        = pick_a ? a_die        : b_die;
  assign m_kind       = pick_a ? a_kind       : b_kind;
  assign m_addr       = pick_a ? a_addr       : b_addr;
  assign m_wdat_valid = pick_a ? a_wdat_valid : pick_b ? b_wdat_valid : 1'b0;
  assign m_wdat       = pick_a ? a_wdat       : b_wdat;
  assign m_rdat_ready = pick_a ? a_rdat_ready : pick_b ? b_rdat_ready : 1'b1;

  assign a_cmd_ready  = pick_a && m_cmd_ready;
  assign b_cmd_ready  = pick_b && m_cmd_ready;
  assign a_wdat_ready = pick_a && m_wdat_ready;
  assign b_wdat_ready = pick_b && m_wdat_ready;
  assign a_rdat_valid = pick_a && m_rdat_valid;
  assign b_rdat_valid = pick_b && m_rdat_valid;
  assign a_done = pick_a && m_done;
  assign b_done = pick_b && m_done;
  assign a_err  = pick_a && m_err;
  assign b_err  = pick_b && m_err;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) g_q <= M_NONE;
    else begin
      if (g_q == M_NONE) begin
        if (m_cmd_valid && m_cmd_ready) g_q <= pick_a ? M_A : M_B;
      end else if (m_done || m_err) begin
        g_q <= M_NONE;
      end
    end
  end
endmodule

// APB window for 32-bit SPI reads and writes.
// APB waits for SPI completion; disabled accesses and timeouts return PSLVERR.
module tj_spiwin (
  input  logic        clk,
  input  logic        rst_n,
  // APB window interface (controller offsets 0x4000..0x4FFF).
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,       // Byte offset within the 4 KiB window.
  input  logic [31:0] pwdata,
  output logic        pready,
  output logic        pslverr,
  output logic [31:0] prdata,
  // Window configuration from CSR.
  input  logic        en,
  input  logic [4:0]  page_die,    // Global die ID (0..31).
  input  logic [19:0] offs,        // Chip address bits [31:12].
  // Window status and timeout event returned to CSR.
  output logic        busy_o,
  output logic        err_set_o,
  // SPI transaction interface (selected group's arbiter A port).
  output logic        cmd_valid,
  input  logic        cmd_ready,
  output logic [4:0]  die_id,
  output logic [1:0]  cmd_kind,
  output logic [31:0] addr,
  output logic        wdat_valid,
  input  logic        wdat_ready,
  output logic [31:0] wdat,
  input  logic        rdat_valid,
  output logic        rdat_ready,
  input  logic [31:0] rdat,
  input  logic        done,
  input  logic        err_timeout
);
  typedef enum logic [2:0] {W_IDLE, W_CMD, W_WAIT, W_ACK, W_DRAIN} st_e;
  st_e st_q;
  logic is_rd_q, err_q;
  logic [31:0] rdata_q;

  wire access = psel && penable;
  assign rdat_ready = 1'b1;
  assign busy_o     = (st_q != W_IDLE);
  assign prdata     = rdata_q;
  // Respond once per APB access.
  assign pready  = (st_q == W_ACK);
  assign pslverr = (st_q == W_ACK) && err_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= W_IDLE; cmd_valid <= 1'b0; wdat_valid <= 1'b0;
      die_id <= '0; cmd_kind <= '0; addr <= '0; wdat <= '0;
      is_rd_q <= 1'b0; err_q <= 1'b0; rdata_q <= '0; err_set_o <= 1'b0;
    end else begin
      err_set_o <= 1'b0;
      unique case (st_q)
        W_IDLE: if (access) begin
          if (!en) begin
            err_q   <= 1'b1;
            rdata_q <= '0;
            st_q    <= W_ACK;                     // Return an error without issuing SPI.
          end else begin
            is_rd_q   <= !pwrite;
            err_q     <= 1'b0;
            cmd_kind  <= pwrite ? 2'd0 : 2'd2;    // WR1 / RD1
            die_id    <= page_die;
            addr      <= {offs, paddr[11:2], 2'b00}; // Force 4-byte alignment.
            wdat      <= pwdata;
            cmd_valid <= 1'b1;
            st_q      <= W_CMD;
          end
        end
        W_CMD: if (cmd_ready && cmd_valid) begin
          cmd_valid  <= 1'b0;
          wdat_valid <= !is_rd_q;
          st_q       <= W_WAIT;
        end
        W_WAIT: begin
          if (wdat_valid && wdat_ready) wdat_valid <= 1'b0;
          if (rdat_valid && is_rd_q)    rdata_q    <= rdat;
          if (done) st_q <= W_ACK;
          if (err_timeout) begin
            err_q      <= 1'b1;
            err_set_o  <= 1'b1;
            wdat_valid <= 1'b0;
            rdata_q    <= '0;
            st_q       <= W_ACK;
          end
        end
        W_ACK: st_q <= W_DRAIN;                   // One response cycle.
        W_DRAIN: if (!access) st_q <= W_IDLE;     // Wait for PENABLE or PSEL to drop.
        default: st_q <= W_IDLE;
      endcase
    end
  end
endmodule

// Shared SPIWIN and per-group doorbell, arbiter, and engine instances.
module tj_spi_subsys
  import tj_ctrl_pkg::*, tj_ctrl_csr_pkg::*;
(
  input  logic          pclk,
  input  logic          presetn,
  input  tj_csr_o_t     hwo,
  // Status and events returned to the parent CSR interface.
  output logic [7:0][31:0] spi_rdata_o,
  output logic [7:0]       spi_busy_o,      // Doorbell busy (SPI.STA.BUSY).
  output logic [7:0]       eng_busy_o,      // Engine busy, including SPIWIN (GLB.STA.SPI_BUSY).
  output logic [7:0]       spi_done_set_o,
  output logic [7:0]       spi_err_set_o,
  output logic             spiwin_busy_o,
  output logic             spiwin_err_set_o,
  // BOOT 引擎全局事务主口(批次 BOOT;经 gmux 与 SPIWIN 合流)
  input  logic          bt_cmd_valid,
  output logic          bt_cmd_ready,
  input  logic [4:0]    bt_die,
  input  logic [1:0]    bt_kind,
  input  logic [31:0]   bt_addr,
  input  logic          bt_wdat_valid,
  output logic          bt_wdat_ready,
  input  logic [31:0]   bt_wdat,
  output logic          bt_rdat_valid,
  input  logic          bt_rdat_ready,
  output logic [31:0]   bt_rdat,
  output logic          bt_done,
  output logic          bt_err,
  // APB window interface.
  input  logic          win_psel,
  input  logic          win_penable,
  input  logic          win_pwrite,
  input  logic [11:0]   win_paddr,
  input  logic [31:0]   win_pwdata,
  output logic          win_pready,
  output logic          win_pslverr,
  output logic [31:0]   win_prdata,
  // Group-shared SCLK/MOSI; separate CS/MISO per die.
  output logic [N_SPI_GRP-1:0] spi_sclk,
  output logic [N_SPI_GRP-1:0] spi_mosi,
  output logic [N_DIE-1:0]     spi_cs_n,
  input  logic [N_DIE-1:0]     spi_miso
);

  // SPIWIN request signals.
  logic        ww_cmd_valid, ww_cmd_ready;
  logic [4:0]  ww_die;
  logic [1:0]  ww_kind;
  logic [31:0] ww_addr, ww_wdat;
  logic        ww_wdat_valid, ww_wdat_ready;
  logic        ww_rdat_valid, ww_rdat_ready;
  logic        ww_done, ww_err;
  // Shared global master to the group dispatch logic.
  logic        w_cmd_valid, w_cmd_ready;
  logic [4:0]  w_die;
  logic [1:0]  w_kind;
  logic [31:0] w_addr, w_wdat;
  logic        w_wdat_valid, w_wdat_ready;
  logic        w_rdat_valid, w_rdat_ready;
  logic [31:0] w_rdat;
  logic        w_done, w_err;

  assign bt_rdat = w_rdat;

  // Responses from each group's arbiter A port.
  logic [N_SPI_GRP-1:0] g_cmd_ready, g_wdat_ready, g_rdat_valid, g_done, g_err;
  logic [N_SPI_GRP-1:0][31:0] g_rdat;

  wire [2:0] w_grp = w_die[4:2];
  assign w_cmd_ready  = g_cmd_ready[w_grp];
  assign w_wdat_ready = g_wdat_ready[w_grp];
  assign w_rdat_valid = g_rdat_valid[w_grp];
  assign w_rdat       = g_rdat[w_grp];
  assign w_done       = g_done[w_grp];
  assign w_err        = g_err[w_grp];

  tj_spiwin u_win (
    .clk(pclk), .rst_n(presetn),
    .psel(win_psel), .penable(win_penable), .pwrite(win_pwrite),
    .paddr(win_paddr), .pwdata(win_pwdata),
    .pready(win_pready), .pslverr(win_pslverr), .prdata(win_prdata),
    .en(hwo.spiwin_ctrl_en), .page_die(hwo.spiwin_page_die), .offs(hwo.spiwin_offs),
    .busy_o(spiwin_busy_o), .err_set_o(spiwin_err_set_o),
    .cmd_valid(ww_cmd_valid), .cmd_ready(ww_cmd_ready),
    .die_id(ww_die), .cmd_kind(ww_kind), .addr(ww_addr),
    .wdat_valid(ww_wdat_valid), .wdat_ready(ww_wdat_ready), .wdat(ww_wdat),
    .rdat_valid(ww_rdat_valid), .rdat_ready(ww_rdat_ready), .rdat(w_rdat),
    .done(ww_done), .err_timeout(ww_err)
  );

  tj_spi_gmux u_gmux (
    .clk(pclk), .rst_n(presetn),
    .a_cmd_valid(ww_cmd_valid), .a_cmd_ready(ww_cmd_ready),
    .a_die(ww_die), .a_kind(ww_kind), .a_addr(ww_addr),
    .a_wdat_valid(ww_wdat_valid), .a_wdat_ready(ww_wdat_ready), .a_wdat(ww_wdat),
    .a_rdat_valid(ww_rdat_valid), .a_rdat_ready(ww_rdat_ready),
    .a_done(ww_done), .a_err(ww_err),
    .b_cmd_valid(bt_cmd_valid), .b_cmd_ready(bt_cmd_ready),
    .b_die(bt_die), .b_kind(bt_kind), .b_addr(bt_addr),
    .b_wdat_valid(bt_wdat_valid), .b_wdat_ready(bt_wdat_ready), .b_wdat(bt_wdat),
    .b_rdat_valid(bt_rdat_valid), .b_rdat_ready(bt_rdat_ready),
    .b_done(bt_done), .b_err(bt_err),
    .m_cmd_valid(w_cmd_valid), .m_cmd_ready(w_cmd_ready),
    .m_die(w_die), .m_kind(w_kind), .m_addr(w_addr),
    .m_wdat_valid(w_wdat_valid), .m_wdat_ready(w_wdat_ready), .m_wdat(w_wdat),
    .m_rdat_valid(w_rdat_valid), .m_rdat_ready(w_rdat_ready),
    .m_done(w_done), .m_err(w_err)
  );

  for (genvar g = 0; g < N_SPI_GRP; g++) begin : g_grp
    // Doorbell transaction signals (arbiter B port).
    logic        d_cmd_valid, d_cmd_ready;
    logic [4:0]  d_die;
    logic [1:0]  d_kind;
    logic [31:0] d_addr, d_wdat;
    logic        d_wdat_valid, d_wdat_ready;
    logic        d_rdat_valid, d_rdat_ready;
    logic        d_done, d_err;
    // Engine transaction signals.
    logic        e_cmd_valid, e_cmd_ready;
    logic [4:0]  e_die;
    logic [1:0]  e_kind;
    logic [31:0] e_addr, e_wdat;
    logic        e_wdat_valid, e_wdat_ready;
    logic        e_rdat_valid, e_rdat_ready;
    logic [31:0] e_rdat;
    logic        e_done, e_err;
    logic [31:0] rdat_bus;

    wire a_sel = w_cmd_valid && (w_grp == 3'(g));

    tj_spi_doorbell u_db (
      .clk(pclk), .rst_n(presetn),
      .db_go(hwo.spi_db_go[g]),
      .csr_kind(hwo.spi_cmd_kind[g]), .csr_die(hwo.spi_cmd_die[g]),
      .csr_addr(hwo.spi_addr[g]), .csr_wdata(hwo.spi_wdata[g]),
      .grp_id(3'(g)),
      .rdata_o(spi_rdata_o[g]), .busy_o(spi_busy_o[g]),
      .done_set_o(spi_done_set_o[g]), .err_set_o(spi_err_set_o[g]),
      .cmd_valid(d_cmd_valid), .cmd_ready(d_cmd_ready),
      .die_id(d_die), .cmd_kind(d_kind), .addr(d_addr),
      .wdat_valid(d_wdat_valid), .wdat_ready(d_wdat_ready), .wdat(d_wdat),
      .rdat_valid(d_rdat_valid), .rdat_ready(d_rdat_ready), .rdat(rdat_bus),
      .done(d_done), .err_timeout(d_err)
    );

    tj_spi_arb2 u_arb (
      .clk(pclk), .rst_n(presetn),
      .a_cmd_valid(a_sel), .a_cmd_ready(g_cmd_ready[g]),
      .a_die(w_die), .a_kind(w_kind), .a_addr(w_addr),
      .a_wdat_valid(w_wdat_valid && (w_grp == 3'(g))), .a_wdat_ready(g_wdat_ready[g]),
      .a_wdat(w_wdat),
      .a_rdat_valid(g_rdat_valid[g]), .a_rdat_ready(w_rdat_ready),
      .a_done(g_done[g]), .a_err(g_err[g]),
      .b_cmd_valid(d_cmd_valid), .b_cmd_ready(d_cmd_ready),
      .b_die(d_die), .b_kind(d_kind), .b_addr(d_addr),
      .b_wdat_valid(d_wdat_valid), .b_wdat_ready(d_wdat_ready), .b_wdat(d_wdat),
      .b_rdat_valid(d_rdat_valid), .b_rdat_ready(d_rdat_ready),
      .b_done(d_done), .b_err(d_err),
      .e_cmd_valid(e_cmd_valid), .e_cmd_ready(e_cmd_ready),
      .e_die(e_die), .e_kind(e_kind), .e_addr(e_addr),
      .e_wdat_valid(e_wdat_valid), .e_wdat_ready(e_wdat_ready), .e_wdat(e_wdat),
      .e_rdat_valid(e_rdat_valid), .e_rdat_ready(e_rdat_ready), .e_rdat(e_rdat),
      .e_done(e_done), .e_err(e_err),
      .rdat_bus(rdat_bus)
    );
    assign g_rdat[g] = rdat_bus;

    tj_spi_engine #(.GRP(g)) u_eng (
      .clk(pclk), .rst_n(presetn),
      .cfg_clkdiv(hwo.spi_clkdiv[g]), .cfg_tmo(hwo.spi_tmo[g]),
      .cmd_valid(e_cmd_valid), .cmd_ready(e_cmd_ready),
      .die_id(e_die), .cmd_kind(e_kind), .addr(e_addr),
      .wdat_valid(e_wdat_valid), .wdat_ready(e_wdat_ready), .wdat(e_wdat),
      .rdat_valid(e_rdat_valid), .rdat_ready(e_rdat_ready), .rdat(e_rdat),
      .done(e_done), .err_timeout(e_err), .busy(eng_busy_o[g]),
      .sclk(spi_sclk[g]), .mosi(spi_mosi[g]),
      .cs_n(spi_cs_n[g*4 +: 4]), .miso(spi_miso[g*4 +: 4])
    );
  end

endmodule
