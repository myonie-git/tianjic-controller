// File        : tj_spi_engine.sv
// Module      : tj_spi_engine
// Description : SPI master for one group of four or eight dies.
//               Mode 0, MSB first; single-word and 16-word reads and writes.

module tj_spi_engine
  import tj_ctrl_pkg::*;
#(
  parameter int unsigned GRP = 0,
  parameter int unsigned DIES_PER_GRP = 4,
  localparam int unsigned DIE_SEL_W = $clog2(DIES_PER_GRP)
)(
  input  logic        clk,
  input  logic        rst_n,
  // Group CSR configuration, latched on command acceptance.
  input  logic [7:0]  cfg_clkdiv,
  input  logic [31:0] cfg_tmo,             // clk cycles; 0 disables the watchdog.
  // SPI transaction interface (group arbiter).
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [4:0]  die_id,
  input  logic [1:0]  cmd_kind,             // 0: WR1; 1: WR16; 2: RD1; 3: RD16.
  input  logic [31:0] addr,
  input  logic        wdat_valid,
  output logic        wdat_ready,
  input  logic [31:0] wdat,
  output logic        rdat_valid,
  input  logic        rdat_ready,
  output logic [31:0] rdat,
  output logic        done,
  output logic        err_timeout,
  output logic        busy,                 // Active transaction or timeout recovery.
  // Group-shared SCLK/MOSI; separate CS/MISO per die.
  output logic        sclk,
  output logic        mosi,
  output logic [DIES_PER_GRP-1:0] cs_n,
  input  logic [DIES_PER_GRP-1:0] miso
);

  if ((DIES_PER_GRP != 4 && DIES_PER_GRP != 8) || GRP >= 32 / DIES_PER_GRP) begin : g_group_guard
    $fatal(1, "SPI requires four or eight dies per group and a valid group index.");
  end

  // Latched command and configuration.
  logic [1:0]  kind_q;
  logic [DIE_SEL_W-1:0] die_q;
  logic [31:0] addr_q;
  logic [7:0]  div_q;
  logic [31:0] tmo_q;

  wire kind_rd   = kind_q[1];               // RD1 / RD16.
  wire kind_blk  = (kind_q == 2'd1) || (kind_q == 2'd3);  // WR16 / RD16.

  // Frame segments and bit counters.
  typedef enum logic [1:0] {SEG_CMD, SEG_ADDR, SEG_DATA} seg_e;
  seg_e        seg_q;
  logic [4:0]  wcnt_q;                      // Words remaining, including the current word.
  logic        phase_b_q;                   // Read fetch frame.
  logic [5:0]  bitcnt_q;                    // Bit index within the current segment.
  logic [5:0]  bitlen_q;                    // Segment length: 8 or 32 bits.
  logic [31:0] shreg_q;                     // TX shift register; sends zeros during RX data.
  logic [31:0] rxreg_q;                     // RX shift register.
  logic        rx_seg_q;                    // Receive data segment.

  // Transfer state.
  typedef enum logic [3:0] {
    S_IDLE, S_SETUP, S_LOAD, S_LOW, S_HIGH, S_HOLD, S_GAP, S_NEXTPH, S_DONE, S_ABORT
  } st_e;
  st_e st_q;

  logic [7:0]  half_q;                      // SCLK half-period counter.
  logic [7:0]  wait_q;                      // CS setup, hold, gap and recovery counter.
  logic [31:0] wdog_q;                      // Elapsed transaction cycles.

  // One-word read buffer.
  logic        skid_v_q;
  logic [31:0] skid_q;

  assign rdat       = skid_q;
  assign rdat_valid = skid_v_q;
  assign mosi       = shreg_q[31];
  // Wait for the previous read result to be consumed before accepting a command.
  assign cmd_ready  = (st_q == S_IDLE) && !skid_v_q;

  // Direct MISO sampling; account for board round-trip delay.
  wire [DIES_PER_GRP-1:0] miso_sel = miso >> die_q;
  wire       miso_bit = miso_sel[0];
  assign busy = (st_q != S_IDLE);

  // Reads use a request frame followed by a fetch frame at the same address.
  // Each frame starts with an 8-bit command and a 32-bit address.
  logic [7:0] cur_cmd;
  always_comb begin
    unique case ({phase_b_q, kind_q})
      {1'b0, 2'd0}: cur_cmd = SPI_CMD_WR1;
      {1'b0, 2'd1}: cur_cmd = SPI_CMD_WR16;
      {1'b0, 2'd2}: cur_cmd = SPI_CMD_RDREQ;
      {1'b0, 2'd3}: cur_cmd = SPI_CMD_RDREQ16;
      {1'b1, 2'd2}: cur_cmd = SPI_CMD_RD1;
      {1'b1, 2'd3}: cur_cmd = SPI_CMD_RD16;
      default:      cur_cmd = SPI_CMD_WR1;
    endcase
  end

  // Frame payload and direction.
  wire frame_has_data = phase_b_q ? kind_rd : !kind_rd;   // Read payload is in the fetch frame.
  wire frame_rx       = phase_b_q && kind_rd;
  wire [4:0] frame_words = kind_blk ? 5'd16 : 5'd1;

  wire seg_done = (bitcnt_q + 6'd1 == bitlen_q);
  wire last_data_word = (wcnt_q == 5'd1);

  // SCLK = clk / (2 * (div_eff + 1)); software must keep SCLK <= 25 MHz.
  wire [7:0] div_eff = (div_q < SPI_CLKDIV_MIN[7:0]) ? SPI_CLKDIV_MIN[7:0] : div_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q        <= S_IDLE;
      sclk        <= 1'b0;
      cs_n        <= '1;
      shreg_q     <= '0;
      rxreg_q     <= '0;
      kind_q      <= '0;
      die_q       <= '0;
      addr_q      <= '0;
      div_q       <= 8'd4;
      tmo_q       <= '0;
      seg_q       <= SEG_CMD;
      wcnt_q      <= '0;
      phase_b_q   <= 1'b0;
      bitcnt_q    <= '0;
      bitlen_q    <= '0;
      rx_seg_q    <= 1'b0;
      half_q      <= '0;
      wait_q      <= '0;
      wdog_q      <= '0;
      skid_v_q    <= 1'b0;
      skid_q      <= '0;
      done        <= 1'b0;
      err_timeout <= 1'b0;
      wdat_ready  <= 1'b0;
    end else begin
      done        <= 1'b0;
      err_timeout <= 1'b0;
      wdat_ready  <= 1'b0;

      // Consume the buffered read word.
      if (skid_v_q && rdat_ready)
        skid_v_q <= 1'b0;

      unique case (st_q)
        S_IDLE: begin
          sclk <= 1'b0;
          cs_n <= '1;
          if (cmd_valid && cmd_ready) begin
            kind_q    <= cmd_kind;
            die_q     <= die_id[DIE_SEL_W-1:0];
            addr_q    <= addr;
            div_q     <= cfg_clkdiv;
            tmo_q     <= cfg_tmo;
            phase_b_q <= 1'b0;
            st_q      <= S_SETUP;
            wait_q    <= '0;
          end
        end

        S_SETUP: begin                       // CS setup time.
          cs_n[die_q] <= 1'b0;
          wait_q <= wait_q + 8'd1;
          if (wait_q >= SPI_CS_SETUP_CYC[7:0] - 8'd1) begin
            seg_q  <= SEG_CMD;
            wcnt_q <= frame_words;
            st_q   <= S_LOAD;
          end
        end

        S_LOAD: begin                        // Load a segment; wait with SCLK low.
          bitcnt_q <= '0;
          half_q   <= '0;
          unique case (seg_q)
            SEG_CMD: begin
              shreg_q  <= {cur_cmd, 24'h0};
              bitlen_q <= 6'd8;
              rx_seg_q <= 1'b0;
              st_q     <= S_LOW;
            end
            SEG_ADDR: begin
              shreg_q  <= addr_q;
              bitlen_q <= 6'd32;
              rx_seg_q <= 1'b0;
              st_q     <= S_LOW;
            end
            default: begin                   // SEG_DATA
              bitlen_q <= 6'd32;
              if (frame_rx) begin
                shreg_q  <= '0;
                rx_seg_q <= 1'b1;
                if (!skid_v_q)
                  st_q <= S_LOW;
              end else begin
                rx_seg_q <= 1'b0;
                if (wdat_valid) begin
                  shreg_q    <= wdat;
                  wdat_ready <= 1'b1;                   // Accept one write word.
                  st_q       <= S_LOW;
                end
              end
            end
          endcase
        end

        S_LOW: begin                         // Low half-cycle; sample on the rising edge.
          half_q <= half_q + 8'd1;
          if (half_q >= div_eff) begin
            half_q <= '0;
            sclk   <= 1'b1;
            if (rx_seg_q)
              rxreg_q <= {rxreg_q[30:0], miso_bit};
            st_q <= S_HIGH;
          end
        end

        S_HIGH: begin                        // High half-cycle; shift on the falling edge.
          half_q <= half_q + 8'd1;
          if (half_q >= div_eff) begin
            half_q  <= '0;
            sclk    <= 1'b0;
            shreg_q <= {shreg_q[30:0], 1'b0};
            if (!seg_done) begin
              bitcnt_q <= bitcnt_q + 6'd1;
              st_q     <= S_LOW;
            end else begin
              // The last rising edge completed the received word.
              if (rx_seg_q) begin
                skid_q   <= rxreg_q;
                skid_v_q <= 1'b1;
              end
              unique case (seg_q)
                SEG_CMD: begin
                  seg_q <= SEG_ADDR;
                  st_q  <= S_LOAD;
                end
                SEG_ADDR: begin
                  if (frame_has_data) begin
                    seg_q <= SEG_DATA;
                    st_q  <= S_LOAD;
                  end else begin
                    wait_q <= '0;
                    st_q   <= S_HOLD;
                  end
                end
                default: begin               // SEG_DATA
                  if (!last_data_word) begin
                    wcnt_q <= wcnt_q - 5'd1;
                    st_q   <= S_LOAD;
                  end else begin
                    wait_q <= '0;
                    st_q   <= S_HOLD;
                  end
                end
              endcase
            end
          end
        end

        S_HOLD: begin                        // Hold CS low after the last SCLK edge.
          wait_q <= wait_q + 8'd1;
          if (wait_q >= SPI_CS_HOLD_CYC[7:0] - 8'd1) begin
            cs_n   <= '1;
            wait_q <= '0;
            st_q   <= S_GAP;
          end
        end

        S_GAP: begin
          // Keep CS high while the chip drains WR16/RDREQ16 AHB bursts.
          // Read fetch frames use the normal gap.
          wait_q <= wait_q + 8'd1;
          if (wait_q >= ((kind_blk && !phase_b_q) ? SPI_BLKDRAIN_GAP_CYC[7:0]
                                                  : SPI_CS_GAP_CYC[7:0]) - 8'd1)
            st_q <= S_NEXTPH;
        end

        S_NEXTPH: begin
          if (kind_rd && !phase_b_q) begin   // Start the read fetch frame.
            phase_b_q <= 1'b1;
            wait_q    <= '0;
            st_q      <= S_SETUP;
          end else begin
            st_q <= S_DONE;
          end
        end

        S_DONE: begin
          done <= 1'b1;
          st_q <= S_IDLE;
        end

        S_ABORT: begin                       // Release CS and wait before reporting timeout.
          sclk     <= 1'b0;
          cs_n     <= '1;
          skid_v_q <= 1'b0;
          wait_q   <= wait_q + 8'd1;
          if (wait_q >= ((kind_blk && !phase_b_q) ? SPI_BLKDRAIN_GAP_CYC[7:0]
                                                  : SPI_CS_GAP_CYC[7:0]) - 8'd1) begin
            err_timeout <= 1'b1;
            st_q <= S_IDLE;
          end
        end
        default: st_q <= S_IDLE;
      endcase

      // Timeout handling overrides the normal state transition.
      if (st_q == S_IDLE || st_q == S_ABORT)
        wdog_q <= '0;
      else if (tmo_q != '0)
        wdog_q <= wdog_q + 32'd1;
      if ((tmo_q != '0) && (wdog_q >= tmo_q) &&
          (st_q != S_IDLE) && (st_q != S_ABORT) && (st_q != S_DONE)) begin
        st_q   <= S_ABORT;
        wait_q <= '0;
        sclk   <= 1'b0;   // Suppress a rising SCLK edge on the timeout cycle.
      end
    end
  end

`ifdef TJ_ASSERT_ON
  // Accepted commands must target this group.
  property p_die_grp;
    @(posedge clk) disable iff (!rst_n) (cmd_valid && cmd_ready) |-> ((die_id >> DIE_SEL_W) == 5'(GRP));
  endproperty
  a_die_grp: assert property (p_die_grp);
`endif

endmodule
