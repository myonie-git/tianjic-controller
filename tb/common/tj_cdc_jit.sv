// File        : tj_cdc_jit.sv
// Module      : tj_sync2, tj_evt_sync, tj_pulse_sync, tj_snap_sync
// Description : Simulation-only CDC models with random one-cycle sampling delays.
`ifndef TJ_CDC_SV
`define TJ_CDC_SV

module tj_sync2 #(
  parameter int unsigned W = 1
)(
  input  logic         clk,
  input  logic         rst_n,
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);
  logic [W-1:0] meta_q, skip_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      meta_q <= '0;
      q      <= '0;
      skip_q <= '0;
    end else begin
      for (int i = 0; i < W; i++) begin
        if ((d[i] !== meta_q[i]) && !skip_q[i] && ($urandom_range(0, 1) == 1)) begin
          skip_q[i] <= 1'b1;
        end else begin
          meta_q[i] <= d[i];
          skip_q[i] <= 1'b0;
        end
      end
      q <= meta_q;
    end
endmodule

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

  logic [W-1:0] s0_q, s1_q, s2_q, skip_q;
  always_ff @(posedge dclk or negedge drst_n)
    if (!drst_n) begin
      s0_q <= '0; s1_q <= '0; s2_q <= '0; skip_q <= '0;
    end else begin
      for (int i = 0; i < W; i++) begin
        if ((tgl_q[i] !== s0_q[i]) && !skip_q[i] && ($urandom_range(0, 1) == 1)) begin
          skip_q[i] <= 1'b1;
        end else begin
          s0_q[i]   <= tgl_q[i];
          skip_q[i] <= 1'b0;
        end
      end
      s1_q <= s0_q; s2_q <= s1_q;
    end
  assign set_o = s2_q ^ s1_q;
endmodule

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
  logic       skip_q;

  always_ff @(posedge sclk or negedge srst_n)
    if (!srst_n) tgl_q <= 1'b0;
    else if (pulse_i) tgl_q <= ~tgl_q;

  always_ff @(posedge dclk or negedge drst_n)
    if (!drst_n) begin
      syn_q  <= '0;
      skip_q <= 1'b0;
    end else begin
      if ((tgl_q !== syn_q[0]) && !skip_q && ($urandom_range(0, 1) == 1)) begin
        skip_q <= 1'b1;
        syn_q  <= {syn_q[1:0], syn_q[0]};
      end else begin
        skip_q <= 1'b0;
        syn_q  <= {syn_q[1:0], tgl_q};
      end
    end

  assign pulse_o = syn_q[2] ^ syn_q[1];
endmodule

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
