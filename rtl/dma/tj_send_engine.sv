// File        : tj_send_engine.sv
// Module      : tj_send_engine
// Description : Dispatch record payloads to LVDS ports with per-port buffering.
// All signals use clk; configuration stays stable while busy.
module tj_send_engine
  import tj_ctrl_pkg::*;
#(
  parameter int unsigned N_CH     = N_CH_V1,
  parameter int unsigned N_PORTS  = ((N_CH + 2) / 3) * N_LVDS_PORTS
)(
  input  logic                     clk,
  input  logic                     rst_n,
  // Task control (maxi_clk).
  input  logic                     go,  // Start pulse; issue only when idle.
  input  logic                     abort,        // Stop new records; drain pending packets.
  input  logic [11:0]              cfg_lnk_en,
  // Logical channels 0..7 to physical groups; 4 bits each.
  input  logic [31:0]              cfg_remap0,
  input  logic [15:0]              cfg_remap1,   // Logical channels 8..11 to physical groups.
  output logic                     busy,
  output logic                     done_pulse,  // Task completion; not asserted for abort.
  output logic                     err_pulse,    // Pulse for a dropped invalid or disabled record.
  output logic                     irq_pulse,    // IRQ-marked packet accepted by LVDS.
  output logic [31:0]              sent,  // Packets accepted by LVDS; cleared by go.
  // Record stream from tj_send_fetch.
  input  logic                     rec_valid,
  output logic                     rec_ready,
  input  tj_rec_t                  rec,
  // Fetch has drained its reads; buffered records may remain.
  input  logic                     src_done,
  // LVDS TX ports, ordered by instance then port within the instance.
  output logic [N_PORTS-1:0]       tx_tvalid,
  input  logic [N_PORTS-1:0]       tx_tready,
  output logic [N_PORTS-1:0][95:0] tx_tdata
);
  // Task state and accepted packet count.
  logic        run_q;
  logic [31:0] sent_q;
  logic        done_q;        // Completion already reported for this task.

  // One packet per output port; each port handshakes independently.
  logic [N_PORTS-1:0]       skid_v_q;
  logic [N_PORTS-1:0][95:0] skid_d_q;
  logic [N_PORTS-1:0]       skid_irq_q;

  assign tx_tvalid = skid_v_q;
  assign tx_tdata  = skid_d_q;

  logic [N_PORTS-1:0] ev_accept;
  assign ev_accept = skid_v_q & tx_tready;

  logic all_skid_empty;
  assign all_skid_empty = (skid_v_q == '0);

  // Channel remapping and validation.
  logic [3:0] log_ch;
  logic [3:0] phys;
  always_comb begin
    log_ch = rec.ch[3:0];
    phys   = (log_ch < 4'd8) ? cfg_remap0[4*log_ch +: 4]
                             : cfg_remap1[4*(log_ch-4'd8) +: 4];
  end

  logic rec_illegal;   // Invalid channel, disabled channel or out-of-range mapping.
  always_comb begin
    rec_illegal = 1'b0;
    if (rec.ch > 8'd11)            rec_illegal = 1'b1;
    else if (!cfg_lnk_en[log_ch])  rec_illegal = 1'b1;
    else if (32'(phys) >= N_CH)    rec_illegal = 1'b1;
  end

  // Map each group of three channels to ports 0..2 of an LVDS instance.
  logic [$clog2(N_PORTS)-1:0] tgt_port;
  assign tgt_port = ($clog2(N_PORTS))'((32'(phys) / 3) * N_LVDS_PORTS + (32'(phys) % 3));

  // Wait until all earlier packets have been accepted.
  logic fence_hold;
  assign fence_hold = rec.flags[FLAG_FENCE] && !all_skid_empty;

  // Allow refill when the current packet is accepted.
  logic can_take;
  assign can_take = run_q && rec_valid && !fence_hold
                    && (rec_illegal || !skid_v_q[tgt_port] || tx_tready[tgt_port]);
  assign rec_ready = can_take;

  logic ev_take_ok, ev_take_bad;
  assign ev_take_ok  = can_take && !rec_illegal;
  assign ev_take_bad = can_take &&  rec_illegal;

  logic stream_finished;
  assign stream_finished = src_done && !rec_valid;

  logic ev_done;
  assign ev_done = run_q && !done_q && stream_finished && all_skid_empty;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run_q      <= 1'b0;
      done_q     <= 1'b0;
      sent_q     <= '0;
      skid_v_q   <= '0;
      skid_d_q   <= '0;
      skid_irq_q <= '0;
      irq_pulse  <= 1'b0;
      done_pulse <= 1'b0;
      err_pulse  <= 1'b0;
    end else begin
      done_pulse <= 1'b0;
      irq_pulse  <= 1'b0;
      err_pulse  <= 1'b0;

      // Retire accepted packets during abort draining.
      for (int p = 0; p < N_PORTS; p++) begin
        if (ev_accept[p]) begin
          skid_v_q[p] <= 1'b0;
          if (skid_irq_q[p]) irq_pulse <= 1'b1;
        end
      end
      if (ev_accept != '0)
        sent_q <= sent_q + 32'($countones(ev_accept));

      if (go) begin
        run_q      <= 1'b1;
        done_q     <= 1'b0;
        sent_q     <= '0;
      end else if (abort && run_q) begin
        run_q      <= 1'b0;
      end else if (run_q) begin
        // Load the selected output buffer.
        if (ev_take_ok) begin
          skid_v_q  [tgt_port] <= 1'b1;
          skid_d_q  [tgt_port] <= rec.pkt;
          skid_irq_q[tgt_port] <= rec.flags[FLAG_IRQ];
        end
        if (ev_take_bad) err_pulse <= 1'b1;

        // Report completion after the input and all output buffers drain.
        if (ev_done) begin
          done_q     <= 1'b1;
          done_pulse <= 1'b1;
          run_q      <= 1'b0;
        end
      end
    end
  end

  assign busy = run_q || !all_skid_empty;
  assign sent = sent_q;

endmodule
