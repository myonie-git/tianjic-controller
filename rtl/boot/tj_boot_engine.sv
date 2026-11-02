// =============================================================================
// tj_boot_engine.sv — BOOT 引导引擎(批次 BOOT):DDR → SPI 事务层流式通路
// -----------------------------------------------------------------------------
// 语义(CSR BOOT 块,B1 冻结):
//   KIND=0 FW_LOAD :DDR → 芯片 DST(ILM/DLM),WR16 流(64B/帧;事务层自带
//                    INCR16 后 1µs 排空);LEN=64B 倍数。
//   KIND=1 BOOT_PRIM:DDR 引导链模板 → 核内存窗口,WR1 流。芯片侧实证
//                    (config_top.sv:reg_addr[19:5]=行号、[4:2]=行内 32b 槽,
//                    逐字带掩码独立落行——无行缓冲语义);引擎自带 CLK_SHIFT
//                    序列(0x0208000C=1 → 数据 → =0,该位仅门控内存宏时钟)。
//                    LEN=32B 倍数且 ≤128B(1~4 行)。
//                    **host 契约:门铃前须经 SPIWIN 完成 cfg_pp 选核(02FFF00C)**。
// Error codes: 1 = SPI timeout, 2 = AXI read error, 3 = invalid KIND, LEN or DST.
// Data source: shared AXI read backend; 64-byte blocks use req/ack toggle handshakes.
// SRST:粘滞中止,在事务边界生效(在途 SPI 帧由事务层完成/看门狗兜底);
//   BOOT_PRIM 已开 CLK_SHIFT 的,尽力补 =0;中止不置 DONE。
// =============================================================================

// Fetch one 64-byte block in maxi_clk.
module tj_boot_fetch64 (
  input  logic         maxi_clk,
  input  logic         maxi_rstn,
  input  logic         req_tgl,     // Toggle to request a block.
  output logic         ack_tgl,     // Toggle when the read completes.
  input  logic [47:0]  blk_addr,    // Held from request until ACK returns.
  output logic [3:0][127:0] blk,    // Held after ACK until the next request.
  output logic         blk_err,    // Sticky read error for this block.
  // Shared memory read interface.
  output logic         req_valid,
  input  logic         req_ready,
  output logic [47:0]  req_addr,
  output logic [7:0]   req_len,
  input  logic         rsp_valid,
  output logic         rsp_ready,
  input  logic [127:0] rsp_data,
  input  logic         rsp_last,
  input  logic         rsp_err
);
  // Synchronize the request toggle and detect a new request.
  logic [2:0] req_syn_q;
  always_ff @(posedge maxi_clk or negedge maxi_rstn)
    if (!maxi_rstn) req_syn_q <= '0;
    else            req_syn_q <= {req_syn_q[1:0], req_tgl};
  wire go = req_syn_q[2] ^ req_syn_q[1];

  typedef enum logic [1:0] {F_IDLE, F_REQ, F_RSP} st_e;
  st_e st_q;
  logic [1:0] beat_q;

  assign req_valid = (st_q == F_REQ);
  logic [47:6] addr_q;
  assign req_addr  = {addr_q, 6'h0};
  assign req_len   = 8'd4;
  assign rsp_ready = (st_q == F_RSP);

  always_ff @(posedge maxi_clk or negedge maxi_rstn) begin
    if (!maxi_rstn) begin
      st_q <= F_IDLE; beat_q <= '0; ack_tgl <= 1'b0;
      blk <= '0; blk_err <= 1'b0; addr_q <= '0;
    end else begin
      unique case (st_q)
        F_IDLE: if (go) begin
          addr_q <= blk_addr[47:6];
          beat_q <= '0; blk_err <= 1'b0; st_q <= F_REQ;
        end
        F_REQ: if (req_ready) st_q <= F_RSP;
        F_RSP: if (rsp_valid) begin
          blk[beat_q] <= rsp_data;
          if (rsp_err) blk_err <= 1'b1;
          beat_q <= beat_q + 2'd1;
          if (rsp_last) begin
            ack_tgl <= ~ack_tgl;
            st_q <= F_IDLE;
          end
        end
        default: st_q <= F_IDLE;
      endcase
    end
  end
endmodule

// -----------------------------------------------------------------------------
// pclk 域引擎:相位(CLKON→DATA→CLKOFF)× 统一事务微序列(CMD→DATA→WAIT)
// -----------------------------------------------------------------------------
module tj_boot_engine
  import tj_ctrl_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  // CSR
  input  logic        db_go,
  input  logic        srst,
  input  logic [1:0]  cfg_kind,
  input  logic [4:0]  cfg_die,
  input  logic [47:0] cfg_src,
  input  logic [31:0] cfg_len,
  input  logic [31:0] cfg_dst,
  output logic        busy_o,
  output logic        done_set_o,
  output logic        err_set_o,
  output logic [3:0]  err_code_o,
  // fetch64 握手
  output logic        f_req_tgl,
  input  logic        f_ack_tgl,
  output logic [47:0] f_blk_addr,
  input  logic [3:0][127:0] f_blk,
  input  logic        f_blk_err,
  // SPI 事务全局主口(经 tj_spi_gmux)
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
  typedef enum logic [2:0] {B_IDLE, B_FETCH, B_FETCHW, B_CMD, B_DATA, B_TWAIT, B_FIN} st_e;
  typedef enum logic [1:0] {P_CLKON, P_DATA, P_CLKOFF} ph_e;
  st_e st_q;
  ph_e ph_q;

  logic        prim_q;               // KIND=1
  logic        clkon_done_q;         // CLK_SHIFT=1 已落(终止路径须补 =0)
  logic        abort_q;
  logic [4:0]  die_q;
  logic [47:0] src_q;
  logic [31:0] len_q, dst_q, off_q;
  logic [3:0][127:0] blk_q;
  logic [3:0]  widx_q;               // 块内 32b 字索引
  logic [4:0]  wcnt_q;
  logic        ack_s1_q, ack_s2_q, ack_seen_q;

  // Synchronize the acknowledgement toggle.
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin ack_s1_q <= 0; ack_s2_q <= 0; ack_seen_q <= 0; end
    else begin
      ack_s1_q <= f_ack_tgl; ack_s2_q <= ack_s1_q; ack_seen_q <= ack_s2_q;
    end
  wire ack_pulse = ack_s2_q ^ ack_seen_q;

  wire [31:0] blk_word_nxt = blk_q[widx_q[3:2] + ((widx_q[1:0] == 2'd3) ? 2'd1 : 2'd0)]
                                  [((widx_q[1:0] + 2'd1) & 2'h3) * 32 +: 32];
  wire [31:0] blk_word_cur = blk_q[widx_q[3:2]][widx_q[1:0] * 32 +: 32];

  assign busy_o     = (st_q != B_IDLE) || done_set_o || err_set_o;
  assign die_id     = die_q;
  assign rdat_ready = 1'b1;

  // First byte after the destination range.
  wire [32:0] dst_end_w = {1'b0, cfg_dst} + {1'b0, cfg_len};
  wire fw_bad_dst_w = (cfg_dst[5:0] != 6'd0) || (dst_end_w > 33'h1_0000_0000);
  wire prim_bad_dst_w = (cfg_dst[4:0] != 5'd0) ||
                        (cfg_dst < CHIP_CORE_MEM_BASE) ||
                        (dst_end_w > {1'b0, CHIP_CORE_REG_BASE});

  // 装填 CLK_SHIFT 事务(进 B_CMD 前调用方置好)
  task automatic load_clkshift(input logic v);
    cmd_valid <= 1'b1; cmd_kind <= 2'd0;
    addr      <= CHIP_CORE_REG_BASE | 32'(CORE_REG_CLK_SHIFT);
    wdat      <= {31'h0, v};
    wcnt_q    <= 5'd1;
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= B_IDLE; ph_q <= P_CLKON;
      cmd_valid <= 1'b0; wdat_valid <= 1'b0;
      cmd_kind <= '0; addr <= '0; wdat <= '0;
      done_set_o <= 1'b0; err_set_o <= 1'b0; err_code_o <= '0;
      prim_q <= 1'b0; clkon_done_q <= 1'b0; abort_q <= 1'b0;
      die_q <= '0; src_q <= '0; len_q <= '0; dst_q <= '0; off_q <= '0;
      blk_q <= '0; widx_q <= '0; wcnt_q <= '0;
      f_req_tgl <= 1'b0; f_blk_addr <= '0;
    end else begin
      done_set_o <= 1'b0;
      err_set_o  <= 1'b0;
      if (srst && st_q != B_IDLE) abort_q <= 1'b1;

      unique case (st_q)
        // ------------------------------------------------------------------
        B_IDLE: if (db_go && !busy_o && !srst) begin
          abort_q      <= 1'b0;
          clkon_done_q <= 1'b0;
          prim_q       <= (cfg_kind == 2'd1);
          die_q        <= cfg_die;
          src_q        <= {cfg_src[47:6], 6'h0};
          dst_q        <= cfg_dst;
          len_q        <= cfg_len;
          off_q        <= '0;
          err_code_o   <= '0;
          if (cfg_kind[1] || cfg_len == 0 ||
              (cfg_kind == 2'd0 && (cfg_len[5:0] != 6'h0 || fw_bad_dst_w)) ||
              (cfg_kind == 2'd1 && (cfg_len[4:0] != 5'h0 || cfg_len > 32'd128 ||
                                    prim_bad_dst_w))) begin
            err_code_o <= 4'd3;
            err_set_o  <= 1'b1;
            done_set_o <= 1'b1;
          end else if (cfg_kind == 2'd1) begin
            ph_q <= P_CLKON;
            load_clkshift(1'b1);
            st_q <= B_CMD;
          end else begin
            ph_q <= P_DATA;
            st_q <= B_FETCH;
          end
        end

        // ------------------------------------------------------------------
        B_FETCH: begin
          if (abort_q || srst) begin
            if (prim_q && clkon_done_q) begin
              ph_q <= P_CLKOFF; load_clkshift(1'b0); st_q <= B_CMD;
            end else st_q <= B_FIN;
          end else begin
            f_blk_addr <= src_q + 48'(off_q);
            f_req_tgl  <= ~f_req_tgl;
            st_q <= B_FETCHW;
          end
        end

        B_FETCHW: if (ack_pulse) begin
          blk_q  <= f_blk;
          widx_q <= '0;
          if (f_blk_err || abort_q || srst) begin
            if (f_blk_err) err_code_o <= 4'd2;
            if (prim_q && clkon_done_q) begin
              ph_q <= P_CLKOFF; load_clkshift(1'b0); st_q <= B_CMD;
            end else st_q <= B_FIN;
          end else begin
            ph_q      <= P_DATA;
            cmd_valid <= 1'b1;
            cmd_kind  <= prim_q ? 2'd0 : 2'd1;     // WR1 / WR16
            addr      <= dst_q + off_q;
            wdat      <= f_blk[0][31:0];
            wcnt_q    <= prim_q ? 5'd1 : 5'd16;
            st_q <= B_CMD;
          end
        end

        // ------------------------------------------------------------------
        B_CMD: begin
          if (cmd_ready && cmd_valid) begin
            cmd_valid  <= 1'b0;
            wdat_valid <= 1'b1;
            st_q <= B_DATA;
          end
          if (err_timeout) begin
            cmd_valid <= 1'b0; err_code_o <= 4'd1;
            st_q <= B_FIN;                         // 事务层已死,不再尝试补关
          end
        end

        B_DATA: begin
          if (wdat_valid && wdat_ready) begin
            if (wcnt_q == 5'd1) begin
              wdat_valid <= 1'b0;
              st_q <= B_TWAIT;
            end else begin
              wcnt_q <= wcnt_q - 5'd1;
              wdat   <= blk_word_nxt;
              widx_q <= widx_q + 4'd1;
            end
          end
          if (err_timeout) begin
            wdat_valid <= 1'b0; err_code_o <= 4'd1;
            st_q <= B_FIN;
          end
        end

        B_TWAIT: begin
          if (err_timeout) begin
            err_code_o <= 4'd1;
            st_q <= B_FIN;
          end else if (done) begin
            unique case (ph_q)
              P_CLKON: begin
                clkon_done_q <= 1'b1;
                st_q <= B_FETCH;
              end
              P_DATA: begin
                if (prim_q) begin
                  // WR1 完成:推进一字
                  off_q  <= off_q + 32'd4;
                  widx_q <= widx_q + 4'd1;
                  if (off_q + 32'd4 == len_q) begin
                    ph_q <= P_CLKOFF; load_clkshift(1'b0); st_q <= B_CMD;
                  end else if (abort_q || srst) begin
                    ph_q <= P_CLKOFF; load_clkshift(1'b0); st_q <= B_CMD;
                  end else if (widx_q == 4'd15) begin
                    st_q <= B_FETCH;
                  end else begin
                    cmd_valid <= 1'b1; cmd_kind <= 2'd0;
                    addr   <= dst_q + off_q + 32'd4;
                    wdat   <= blk_word_nxt;
                    wcnt_q <= 5'd1;
                    st_q <= B_CMD;
                  end
                end else begin
                  // WR16 完成:推进一块
                  off_q <= off_q + 32'd64;
                  if (off_q + 32'd64 == len_q || abort_q || srst) st_q <= B_FIN;
                  else st_q <= B_FETCH;
                end
              end
              P_CLKOFF: st_q <= B_FIN;
              default:  st_q <= B_FIN;
            endcase
          end
        end

        // ------------------------------------------------------------------
        B_FIN: begin
          done_set_o <= !(abort_q || srst);
          err_set_o  <= (err_code_o != 4'd0);
          st_q <= B_IDLE;
        end

        default: st_q <= B_IDLE;
      endcase
    end
  end
endmodule
