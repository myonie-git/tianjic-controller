// File        : tj_cfgchain_master.sv
// Module      : tj_cfgchain_master
// Description : Register access over the LVDS configuration chain.
//               The master and all configuration ports share clk.
//
// Address beat: {1'b1, 1'b0, 3'b000, instance[1:0], write, address[24:0]}.
// Data beat: {1'b0, data[31:0]}. Broadcast is disabled.
// Each GO sends one beat. Reads wait for a response or the watchdog threshold.
// A timeout returns idle without setting DVLD. Writes have no response.

module tj_cfgchain_master #(
  parameter int unsigned CC_TIMEOUT = 4096
)(
  input  logic        clk,
  input  logic        rst_n,

  // CSR command and result signals, synchronous to clk.
  input  logic        db_go,
  input  logic [1:0]  kind,  // 0: write address; 1: write data; 2/3: read.
  input  logic [1:0]  inst,
  input  logic [31:0] wdata,
  output logic [31:0] rdata_o,
  output logic        busy_o,
  output logic        dvld_set_o,

  // Connect to the first configuration-chain instance.
  output logic [32:0] din,
  output logic        din_vld,
  input  logic [31:0] dout,
  input  logic        dout_vld
);
  typedef enum logic [1:0] {C_IDLE, C_BEAT, C_WAIT, C_DONE} st_e;
  st_e st_q;
  logic        rd_q;
  logic [15:0] wdog_q;

  // Allow the CSR to latch read results before BUSY clears.
  assign busy_o = (st_q != C_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q       <= C_IDLE;
      din        <= '0;
      din_vld    <= 1'b0;
      rdata_o    <= '0;
      dvld_set_o <= 1'b0;
      rd_q       <= 1'b0;
      wdog_q     <= '0;
    end else begin
      din_vld    <= 1'b0;
      dvld_set_o <= 1'b0;
      unique case (st_q)
        C_IDLE: if (db_go) begin
          unique case (kind)
            2'd0: din <= {1'b1, 1'b0, 3'b000, inst, 1'b1, wdata[24:0]};
            2'd1: din <= {1'b0, wdata};
            default: din <= {1'b1, 1'b0, 3'b000, inst, 1'b0, wdata[24:0]};
          endcase
          rd_q    <= kind[1];

          din_vld <= 1'b1;
          wdog_q  <= '0;
          st_q    <= C_BEAT;
        end
        C_BEAT: st_q <= rd_q ? C_WAIT : C_IDLE;
        C_WAIT: begin
          wdog_q <= wdog_q + 16'd1;
          if (dout_vld) begin
            rdata_o    <= dout;
            dvld_set_o <= 1'b1;
            st_q       <= C_DONE;
          end else if (wdog_q >= CC_TIMEOUT[15:0]) begin
            st_q <= C_IDLE;
          end
        end
        C_DONE: st_q <= C_IDLE;
        default: st_q <= C_IDLE;
      endcase
    end
  end
endmodule
