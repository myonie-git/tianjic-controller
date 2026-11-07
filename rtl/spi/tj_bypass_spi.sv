// File        : tj_bypass_spi.sv
// Module      : tj_bypass_spi
// Description : Optional SPI slave and APB bridge.
//               ENABLE_BYPASS_SPI=0 selects direct APB forwarding.
//               Enabled SPI uses mode 0, MSB first, with SCLK <= pclk/8.
module tj_bypass_spi #(
  parameter int unsigned APB_AW = 16,
  parameter bit ENABLE_BYPASS_SPI = 1'b0
)(
  input  logic              pclk,
  input  logic              presetn,

  // External SPI slave pins.
  input  logic              spi_sclk,
  input  logic              spi_mosi,
  input  logic              spi_ss_n,
  output logic              spi_miso,
  output logic              spi_miso_oe,   // Active-high MISO pin output enable.

  // Upstream APB slave interface.
  input  logic              u_psel,
  input  logic              u_penable,
  input  logic              u_pwrite,
  input  logic [APB_AW-1:0] u_paddr,
  input  logic [31:0]       u_pwdata,
  output logic              u_pready,
  output logic              u_pslverr,
  output logic [31:0]       u_prdata,

  // Downstream APB master interface.
  output logic              d_psel,
  output logic              d_penable,
  output logic              d_pwrite,
  output logic [APB_AW-1:0] d_paddr,
  output logic [31:0]       d_pwdata,
  input  logic              d_pready,
  input  logic              d_pslverr,
  input  logic [31:0]       d_prdata
);

  generate
    if (!ENABLE_BYPASS_SPI) begin : g_direct_apb
      assign d_psel     = u_psel;
      assign d_penable  = u_penable;
      assign d_pwrite   = u_pwrite;
      assign d_paddr    = u_paddr;
      assign d_pwdata   = u_pwdata;
      assign u_pready   = d_pready;
      assign u_pslverr  = d_pslverr;
      assign u_prdata   = d_prdata;
      assign spi_miso   = 1'b0;
      assign spi_miso_oe = 1'b0;
    end else begin : g_bypass
      localparam logic [7:0] B_ALIVE = 8'hA5;   // First response byte.
      localparam logic [7:0] B_OK    = 8'h00;
      localparam logic [7:0] B_ERR   = 8'hEE;   // Frame error response.

      // SPI input synchronization and edge detection.
      logic sclk_s, mosi_s, ss_s;
      tj_sync2 #(.W(3)) u_pin_sync (
        .clk(pclk), .rst_n(presetn),
        .d({spi_sclk, spi_mosi, spi_ss_n}),
        .q({sclk_s,  mosi_s,  ss_s})
      );

      logic sclk_d1_q, ss_d1_q;
      always_ff @(posedge pclk or negedge presetn)
        if (!presetn) begin
          sclk_d1_q <= 1'b0;
          ss_d1_q   <= 1'b1;
        end else begin
          sclk_d1_q <= sclk_s;
          ss_d1_q   <= ss_s;
        end

      wire sck_rise = ~ss_s &  sclk_s & ~sclk_d1_q;  // SPI sampling edge.
      wire ss_fall  = ~ss_s &  ss_d1_q;
      wire ss_rise  =  ss_s & ~ss_d1_q;
      wire ss_high  =  ss_s;

      // SPI byte reception and transmission.
      logic [2:0] bit_q;          // Received bit count modulo eight.
      logic [7:0] rx_sh_q;
      logic [7:0] tx_sh_q;        // Bit 7 drives MISO.
      logic       byte_val_q;     // Received-byte valid pulse.
      logic       byte_val_d1_q;  // Load the TX byte after the protocol update.
      logic [7:0] rx_byte_q;
      logic [7:0] tx_byte_q;      // Next response byte.

      always_ff @(posedge pclk or negedge presetn)
        if (!presetn) begin
          bit_q         <= '0;
          rx_sh_q       <= '0;
          tx_sh_q       <= '0;
          byte_val_q    <= 1'b0;
          byte_val_d1_q <= 1'b0;
          rx_byte_q     <= '0;
        end else begin
          byte_val_q    <= 1'b0;
          byte_val_d1_q <= byte_val_q;
          if (ss_high) begin
            bit_q <= '0;
          end else if (ss_fall) begin
            tx_sh_q <= B_ALIVE;
            bit_q   <= '0;
          end else if (byte_val_d1_q) begin
            tx_sh_q <= tx_byte_q;                    // Load the next response byte.
          end else if (sck_rise) begin
            rx_sh_q <= {rx_sh_q[6:0], mosi_s};
            bit_q   <= bit_q + 3'd1;
            if (bit_q == 3'd7) begin
              rx_byte_q  <= {rx_sh_q[6:0], mosi_s};
              byte_val_q <= 1'b1;
            end else begin
              tx_sh_q    <= {tx_sh_q[6:0], 1'b0};
            end
          end
        end

      assign spi_miso    = tx_sh_q[7];
      // Release MISO asynchronously and enable it after two pclk edges.
      wire miso_reset_n = presetn && !spi_ss_n;
      tj_sync2 #(.W(1)) u_miso_enable (
        .clk(pclk), .rst_n(miso_reset_n),
        .d(1'b1), .q(spi_miso_oe)
      );

      // Frame parser and two-word read FIFO.
      typedef enum logic [2:0] {P_CMD, P_ADDR, P_TURN, P_WDAT, P_RDAT, P_REJ} pst_e;
      pst_e        pst_q;
      logic [7:0]  cmd_q;
      logic [1:0]  acnt_q;        // Address byte count.
      logic [31:0] addr_q;        // Current write address.
      logic [6:0]  len_q;         // Words remaining in the frame.
      logic [1:0]  dcnt_q;        // Byte index within a word.
      logic [31:0] wacc_q;        // Assembled write data.
      logic        err_q;         // Frame error, cleared when SS is released.
      logic        turn_q;        // First read-turnaround byte.

      // Read-data FIFO.
      logic [31:0]       rf_q [2];
      logic              rf_vld_q [2];
      logic              rf_wp_q, rf_rp_q;
      logic              rd_act_q;       // Read prefetch enabled.
      logic [6:0]        pf_left_q;      // Words remaining to prefetch.
      logic [APB_AW-1:0] pf_addr_q;      // Next prefetch address.

      // Single outstanding APB request.
      logic              req_val_q;
      logic              req_wr_q;
      logic [APB_AW-1:0] req_addr_q;
      logic [31:0]       req_wdata_q;
      logic              rsp_discard_q;  // Discard the response from an ended frame.
      logic              rsp_done;
      logic [31:0]       rsp_rdata;
      logic              rsp_slverr;

      wire        cmd_rd   = cmd_q[7];
      wire        cmd_inc  = cmd_q[6];
      wire [31:0] addr_nx  = {addr_q[23:0], rx_byte_q};       // Address including the newly received byte.
      wire [7:0]  rf_byte  = 8'((rf_q[rf_rp_q] >> (8 * (3 - dcnt_q))) & 32'hFF);
      wire        rf_hit   = rf_vld_q[rf_rp_q];

      always_ff @(posedge pclk or negedge presetn)
        if (!presetn) begin
          pst_q      <= P_CMD;
          cmd_q      <= '0;
          acnt_q     <= '0;
          addr_q     <= '0;
          len_q      <= '0;
          dcnt_q     <= '0;
          wacc_q     <= '0;
          err_q      <= 1'b0;
          turn_q     <= 1'b0;
          tx_byte_q  <= 8'h00;
          rf_q[0]    <= '0;
          rf_q[1]    <= '0;
          rf_vld_q[0]<= 1'b0;
          rf_vld_q[1]<= 1'b0;
          rf_wp_q    <= 1'b0;
          rf_rp_q    <= 1'b0;
          rd_act_q   <= 1'b0;
          pf_left_q  <= '0;
          pf_addr_q  <= '0;
          req_val_q  <= 1'b0;
          req_wr_q   <= 1'b0;
          req_addr_q <= '0;
          req_wdata_q<= '0;
          rsp_discard_q <= 1'b0;
        end else begin
          // Complete the pending APB request.
          // Ignore late responses from a frame whose SS was released.
          if (rsp_done) begin
            req_val_q <= 1'b0;
            if (rsp_discard_q) begin
              rsp_discard_q <= 1'b0;
            end else begin
              if (rsp_slverr) err_q <= 1'b1;
              if (!req_wr_q && !rsp_slverr && !err_q) begin
                rf_q[rf_wp_q]     <= rsp_rdata;
                rf_vld_q[rf_wp_q] <= 1'b1;
                rf_wp_q           <= ~rf_wp_q;
              end
            end
          end else if (ss_rise && req_val_q) begin
            rsp_discard_q <= 1'b1;
          end

          if (ss_high) begin
            // Reset frame state while the pending APB transfer finishes.
            pst_q       <= P_CMD;
            acnt_q      <= '0;
            dcnt_q      <= '0;
            err_q       <= 1'b0;
            turn_q      <= 1'b0;
            rd_act_q    <= 1'b0;
            pf_left_q   <= '0;
            rf_vld_q[0] <= 1'b0;
            rf_vld_q[1] <= 1'b0;
            rf_wp_q     <= 1'b0;
            rf_rp_q     <= 1'b0;
          end else if (byte_val_q) begin
            // Process the received byte and prepare the next response.
            case (pst_q)
              P_CMD: begin
                cmd_q     <= rx_byte_q;
                len_q     <= {1'b0, rx_byte_q[5:0]} + 7'd1;
                acnt_q    <= '0;
                tx_byte_q <= rx_byte_q;                       // Command echo.
                if ((rx_byte_q[5:0] != 6'd0) && !rx_byte_q[6]) begin
                  err_q <= 1'b1;                              // Multiword transfers require address increment.
                  pst_q <= P_REJ;
                end else begin
                  pst_q <= P_ADDR;
                end
              end
              P_ADDR: begin
                addr_q    <= addr_nx;
                acnt_q    <= acnt_q + 2'd1;
                tx_byte_q <= err_q ? B_ERR : B_OK;            // Frame status.
                if (acnt_q == 2'd3) begin
                  if ((addr_nx >> APB_AW) != 32'd0) begin
                    err_q <= 1'b1;
                    pst_q <= P_REJ;
                    tx_byte_q <= B_ERR;
                  end else if (cmd_rd) begin
                    pst_q     <= P_TURN;
                    turn_q    <= 1'b1;
                    dcnt_q    <= '0;
                    rd_act_q  <= 1'b1;                        // Start read prefetch.
                    pf_left_q <= {1'b0, cmd_q[5:0]} + 7'd1;
                    pf_addr_q <= addr_nx[APB_AW-1:0];
                  end else begin
                    pst_q  <= P_WDAT;
                    dcnt_q <= '0;
                  end
                end
              end
              P_TURN: begin
                if (turn_q) begin
                  turn_q    <= 1'b0;
                  tx_byte_q <= err_q ? B_ERR : B_OK;          // Second turnaround byte.
                end else begin
                  // Prepare the first read-data byte.
                  pst_q     <= P_RDAT;
                  dcnt_q    <= 2'd1;
                  tx_byte_q <= (err_q || !rf_hit) ? B_ERR : rf_byte;
                  if (!rf_hit) err_q <= 1'b1;                 // Read FIFO underrun.
                end
              end
              P_WDAT: begin
                wacc_q    <= {wacc_q[23:0], rx_byte_q};
                dcnt_q    <= dcnt_q + 2'd1;
                tx_byte_q <= err_q ? B_ERR : B_OK;
                if (dcnt_q == 2'd3) begin
                  if (len_q == 7'd0) begin
                    err_q <= 1'b1;                            // Write exceeds the declared length.
                    tx_byte_q <= B_ERR;
                  end else if (req_val_q) begin
                    err_q <= 1'b1;                            // Previous APB request is still pending.
                    tx_byte_q <= B_ERR;
                  end else begin
                    req_val_q   <= 1'b1;
                    req_wr_q    <= 1'b1;
                    req_wdata_q <= {wacc_q[23:0], rx_byte_q};
                    req_addr_q  <= addr_q[APB_AW-1:0];
                    addr_q      <= cmd_inc ? addr_q + 32'd4 : addr_q;
                    len_q       <= len_q - 7'd1;
                  end
                end
              end
              P_RDAT: begin
                if (len_q == 7'd0) begin
                  err_q     <= 1'b1;                          // Read exceeds the declared length.
                  tx_byte_q <= B_ERR;
                end else begin
                  tx_byte_q <= (err_q || !rf_hit) ? B_ERR : rf_byte;
                  if (!rf_hit) err_q <= 1'b1;
                  dcnt_q <= dcnt_q + 2'd1;                    // Byte index wraps after each word.
                  if (dcnt_q == 2'd3) begin                   // Last byte of this word has been scheduled.
                    rf_vld_q[rf_rp_q] <= 1'b0;
                    rf_rp_q           <= ~rf_rp_q;
                    len_q             <= len_q - 7'd1;
                  end
                end
              end
              default: tx_byte_q <= B_ERR;                    // Error response.
            endcase
          end else begin
            // Prefetch between received-byte events.
            if (rd_act_q && !err_q && !req_val_q && (pf_left_q != 7'd0)
                && !(rf_vld_q[0] && rf_vld_q[1])) begin
              req_val_q  <= 1'b1;
              req_wr_q   <= 1'b0;
              req_addr_q <= pf_addr_q;
              pf_addr_q  <= pf_addr_q + APB_AW'(4);
              pf_left_q  <= pf_left_q - 7'd1;
            end
          end
          // Finish the outstanding APB transfer and stop this frame.
          if (!ss_high &&
              (err_q || (rsp_done && !rsp_discard_q && rsp_slverr))) begin
            pst_q     <= P_REJ;
            rd_act_q  <= 1'b0;
            pf_left_q <= '0;
            tx_byte_q <= B_ERR;
          end
        end

      // Transaction-level round-robin APB arbitration.
      typedef enum logic [2:0] {A_IDLE, A_UP_SET, A_UP_ACC, A_SPI_SET, A_SPI_ACC} ast_e;
      ast_e ast_q;
      logic rr_up_q;              // Prefer upstream at the next arbitration.
      logic u_seen_q;             // Current upstream request has been served.

      wire up_req  = u_psel && !u_seen_q;
      wire spi_req = req_val_q;

      always_ff @(posedge pclk or negedge presetn)
        if (!presetn) begin
          ast_q    <= A_IDLE;
          rr_up_q  <= 1'b1;
          u_seen_q <= 1'b0;
        end else begin
          // A new setup phase permits back-to-back transfers with PSEL held high.
          if (!u_psel || !u_penable) u_seen_q <= 1'b0;
          case (ast_q)
            A_IDLE: begin
              if (up_req && (rr_up_q || !spi_req))       ast_q <= A_UP_SET;
              else if (spi_req && (!rr_up_q || !up_req)) ast_q <= A_SPI_SET;
            end
            A_UP_SET:  ast_q <= A_UP_ACC;
            A_UP_ACC:  if (d_pready) begin
                         ast_q    <= A_IDLE;
                         rr_up_q  <= 1'b0;
                         u_seen_q <= 1'b1;
                       end
            A_SPI_SET: ast_q <= A_SPI_ACC;
            A_SPI_ACC: if (d_pready) begin
                         ast_q   <= A_IDLE;
                         rr_up_q <= 1'b1;
                       end
            default:   ast_q <= A_IDLE;
          endcase
        end

      wire up_own = (ast_q == A_UP_SET) || (ast_q == A_UP_ACC);

      assign d_psel    = (ast_q != A_IDLE);
      assign d_penable = (ast_q == A_UP_ACC) || (ast_q == A_SPI_ACC);
      assign d_pwrite  = up_own ? u_pwrite : req_wr_q;
      assign d_paddr   = up_own ? u_paddr  : req_addr_q;
      assign d_pwdata  = up_own ? u_pwdata : req_wdata_q;

      assign u_pready  = (ast_q == A_UP_ACC) && d_pready;
      assign u_pslverr = u_pready && d_pslverr;
      assign u_prdata  = d_prdata;

      assign rsp_done   = (ast_q == A_SPI_ACC) && d_pready;
      assign rsp_rdata  = d_prdata;
      assign rsp_slverr = d_pslverr;

    `ifdef TJ_ASSERT_ON
      // Check responses that are written into the read FIFO.
      ap_rf_ovfl: assert property (@(posedge pclk) disable iff (!presetn)
        (rsp_done && !rsp_discard_q && !req_wr_q &&
         !rsp_slverr && !err_q) |-> !rf_vld_q[rf_wp_q])
        else $error("tj_bypass_spi: read FIFO overrun");
    `endif
    end
  endgenerate
endmodule
