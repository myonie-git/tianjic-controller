// File        : tj_cdc.sv
// Module      : tj_sync2, tj_evt_sync, tj_pulse_sync, tj_snap_sync
// Description : Clock-domain crossing primitives.
// Dual-clock units require both resets to be asserted together.
`ifndef TJ_CDC_SV
`define TJ_CDC_SV

// Synchronize independent levels or stable configuration bits.
module tj_sync2 #(
  parameter int unsigned W = 1
)(
  input  logic         clk,
  input  logic         rst_n,
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);
  logic [W-1:0] meta_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      meta_q <= '0;
      q      <= '0;
    end else begin
      meta_q <= d;
      q      <= meta_q;
    end
endmodule

// Coalesce events into at most one toggle per bit every 2**DIVW source cycles.
// Require (2**DIVW) * T_sclk > 3 * T_dclk.
module tj_evt_sync #(
  parameter int unsigned W    = 1,
  parameter int unsigned DIVW = 5
)(
  input  logic         sclk,
  input  logic         srst_n,
  input  logic [W-1:0] evt_i,
  input  logic         dclk,
  input  logic         drst_n,
  output logic [W-1:0] set_o
);
  logic [DIVW-1:0] div_q;
  logic            tick;
  logic [W-1:0]    pend_q, tgl_q;
  assign tick = (div_q == '0);

  always_ff @(posedge sclk or negedge srst_n)
    if (!srst_n) begin
      div_q <= '0; pend_q <= '0; tgl_q <= '0;
    end else begin
      div_q <= div_q + 1'b1;
      for (int i = 0; i < W; i++) begin
        if (tick && (pend_q[i] || evt_i[i])) begin
          tgl_q[i]  <= ~tgl_q[i];
          pend_q[i] <= 1'b0;
        end else if (evt_i[i]) begin
          pend_q[i] <= 1'b1;
        end
      end
    end

  logic [W-1:0] s0_q, s1_q, s2_q;
  always_ff @(posedge dclk or negedge drst_n)
    if (!drst_n) begin
      s0_q <= '0; s1_q <= '0; s2_q <= '0;
    end else begin
      s0_q <= tgl_q; s1_q <= s0_q; s2_q <= s1_q;
    end
  assign set_o = s2_q ^ s1_q;
endmodule

// Transfer single-cycle pulses; event spacing must exceed 3 destination clock periods.
module tj_pulse_sync (
  input  logic sclk,
  input  logic srst_n,
  input  logic pulse_i,
  input  logic dclk,
  input  logic drst_n,
  output logic pulse_o
);
  logic       tgl_q;
  logic [2:0] syn_q;

  always_ff @(posedge sclk or negedge srst_n)
    if (!srst_n) tgl_q <= 1'b0;
    else if (pulse_i) tgl_q <= ~tgl_q;

  always_ff @(posedge dclk or negedge drst_n)
    if (!drst_n) begin
      syn_q  <= '0;
    end else begin
      syn_q <= {syn_q[1:0], tgl_q};
    end

  assign pulse_o = syn_q[2] ^ syn_q[1];
endmodule

// Transfer a stable snapshot using a request/acknowledge handshake.
module tj_snap_sync #(
  parameter int unsigned W = 32
)(
  input  logic         sclk,
  input  logic         srst_n,
  input  logic [W-1:0] d,
  input  logic         dclk,
  input  logic         drst_n,
  output logic [W-1:0] q
);
  logic         req_tog_q, ack_tog_q;
  logic         req_s, ack_d;
  logic [W-1:0] snap_q;

  tj_sync2 #(.W(1)) u_req (.clk(sclk), .rst_n(srst_n), .d(req_tog_q), .q(req_s));
  tj_sync2 #(.W(1)) u_ack (.clk(dclk), .rst_n(drst_n), .d(ack_tog_q), .q(ack_d));

  always_ff @(posedge sclk or negedge srst_n)
    if (!srst_n) begin
      ack_tog_q <= 1'b0;
      snap_q    <= '0;
    end else if (req_s != ack_tog_q) begin
      snap_q    <= d;
      ack_tog_q <= req_s;
    end

  always_ff @(posedge dclk or negedge drst_n)
    if (!drst_n) begin
      req_tog_q <= 1'b0;
      q         <= '0;
    end else if (req_tog_q == ack_d) begin
      q         <= snap_q;
      req_tog_q <= ~req_tog_q;
    end
endmodule

`endif // TJ_CDC_SV
