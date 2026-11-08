// File        : tj_recv_engine.sv
// Module      : tj_recv_engine
// Description : Pack LVDS packets into per-channel records and schedule ring writes.
// All signals use clk; keep ring configuration stable while enabled.
module tj_recv_engine
  import tj_ctrl_pkg::*;
#(
  parameter int unsigned N_CH    = N_CH_V1,
  parameter int unsigned N_PORTS = ((N_CH + 2) / 3) * N_LVDS_PORTS,
  parameter int unsigned AW      = 40
)(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     abort,  // Abort pulse; flush buffers and preserve ring pointers.
  input  logic [47:0]              ts,  // Timestamp in the receive clock domain.
  // Per-channel configuration and synchronized host read pointers.
  input  logic [N_CH-1:0][47:0]    cfg_base,
  input  logic [N_CH-1:0][31:0]    cfg_size,  // Ring capacity in records; power of two.
  input  logic [N_CH-1:0][31:0]    cfg_wmark,
  input  logic [N_CH-1:0]          cfg_en,
  input  logic [N_CH-1:0]          cfg_pol,  // 0: drop new packets; 1: backpressure.
  input  logic [31:0]              cfg_remap0, // Logical channels 0..7 to physical groups.
  input  logic [15:0]              cfg_remap1, // Logical channels 8..11 to physical groups.
  input  logic [N_CH-1:0][31:0]    rptr,
  // Status and events in the receive clock domain.
  output logic [N_CH-1:0][31:0]    wptr,  // Completed write-response count, including errors.
  output logic [N_CH-1:0][15:0]    level,
  output logic [N_CH-1:0]          evt_wmark,  // Watermark upward-crossing pulse.
  output logic [N_CH-1:0]          evt_end,  // END-tagged write-response pulse.
  output logic [N_CH-1:0]          evt_ovf,  // Full-ring or abort-drain drop pulse.
  output logic [N_CH-1:0]          idle,  // Disabled, with no buffered or outstanding record.
  // LVDS ports, ordered by instance and port within the instance.
  input  logic [N_PORTS-1:0]       rx_tvalid,
  output logic [N_PORTS-1:0]       rx_tready,
  input  logic [N_PORTS-1:0][95:0] rx_tdata,
  // Single-outstanding record write interface.
  output logic                     wr_valid,
  input  logic                     wr_ready,
  output logic [AW-1:0]            wr_addr,
  output logic [127:0]             wr_data,
  input  logic                     wr_done,
  input  logic                     wr_idle
);
  // Logical channel to LVDS port.
  function automatic int unsigned ch2port(input int unsigned c);
    logic [3:0] g;
    g = (c < 8) ? cfg_remap0[4*c +: 4]
                : cfg_remap1[4*(c-8) +: 4];
    if (32'(g) >= N_CH) g = 4'(c);
    return (32'(g) / 3) * N_LVDS_PORTS + (32'(g) % 3);
  endfunction

  // Ring pointers and per-channel buffers.
  logic [N_CH-1:0][31:0] wi_q;  // Issued writes; used for addressing and full detection.
  logic [N_CH-1:0][31:0] wd_q;  // Completed B responses.
  logic [N_CH-1:0]       buf_v_q;  // One buffered record per channel.
  logic [N_CH-1:0][127:0] buf_d_q;
  logic [N_CH-1:0][AW-1:0] buf_addr_q;
  logic [N_CH-1:0]       buf_end_q;
  logic                  halt_q;  // Block record storage and issuing while draining.

  // Channel and END tag for the outstanding write.
  logic                  inf_v_q;
  logic [$clog2(N_CH)-1:0] inf_ch_q;
  logic                  inf_end_q;

  // Per-channel ring occupancy and packet classification.
  logic [N_CH-1:0][31:0] lvl_issue;
  logic [N_CH-1:0]       full;
  logic [N_CH-1:0]       is_end;
  always_comb begin
    for (int c = 0; c < N_CH; c++) begin
      lvl_issue[c] = wi_q[c] - rptr[c];
      full[c]      = lvl_issue[c] >= cfg_size[c];
      is_end[c]    = rx_tdata[ch2port(c)][2]
                      && !rx_tdata[ch2port(c)][0];
    end
  end

  // Receive readiness and accept/drop decisions.
  logic [N_CH-1:0] take_store, take_drop_dis, take_drop_ovf;
  always_comb begin
    int unsigned p;
    rx_tready     = '0;
    take_store    = '0;
    take_drop_dis = '0;
    take_drop_ovf = '0;
    for (int c = 0; c < N_CH; c++) begin
      p = ch2port(c);
      if (!cfg_en[c]) begin
        rx_tready[p]     = 1'b1;  // Accept and discard while disabled.
        take_drop_dis[c] = rx_tvalid[p];
      end else if (abort || halt_q || full[c]) begin
        if (cfg_pol[c]) rx_tready[p] = 1'b0;  // Backpressure while full or aborting.
        else begin
          rx_tready[p]     = 1'b1;  // Drop the new packet.
          take_drop_ovf[c] = rx_tvalid[p];
        end
      end else begin
        rx_tready[p]  = !buf_v_q[c];  // Wait for the channel buffer to become free.
        take_store[c] = rx_tvalid[p] && !buf_v_q[c];
      end
    end
    // Accept and discard unused port 3 of each LVDS instance.
    for (int p = 0; p < N_PORTS; p++)
      if ((p % N_LVDS_PORTS) == 3) rx_tready[p] = 1'b1;
  end

  // Round-robin selection of a buffered record.
  logic [$clog2(N_CH)-1:0] rr_q;
  logic                    grant_v;
  logic [$clog2(N_CH)-1:0] grant_ch;
  always_comb begin
    int unsigned c;
    grant_v  = 1'b0;
    grant_ch = '0;
    for (int k = 0; k < N_CH; k++) begin
      c = (32'(rr_q) + k) % N_CH;
      if (!grant_v && buf_v_q[c]) begin
        grant_v  = 1'b1;
        grant_ch = ($clog2(N_CH))'(c);
      end
    end
  end

  assign wr_valid = grant_v && !inf_v_q && !halt_q;
  assign wr_addr  = buf_addr_q[grant_ch];
  assign wr_data  = buf_d_q[grant_ch];

  logic wr_take;
  assign wr_take = wr_valid && wr_ready;

  // Occupancy after the pending write response.
  logic [31:0] lvl_done_nxt;
  always_comb begin
    lvl_done_nxt = (wd_q[inf_ch_q] + 32'd1) - rptr[inf_ch_q];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wi_q <= '0; wd_q <= '0;
      buf_v_q <= '0; buf_d_q <= '0; buf_end_q <= '0;
      buf_addr_q <= '0;
      inf_v_q <= 1'b0; inf_ch_q <= '0; inf_end_q <= 1'b0;
      rr_q <= '0; halt_q <= 1'b0;
      evt_wmark <= '0; evt_end <= '0; evt_ovf <= '0;
    end else begin
      evt_wmark <= '0; evt_end <= '0; evt_ovf <= '0;

      // Flush buffers; preserve outstanding writes and pointer state.
      if (abort) begin
        buf_v_q <= '0;
        halt_q  <= 1'b1;
      end else if (halt_q && wr_idle) begin
        halt_q <= 1'b0;  // Resume after the write backend is idle.
      end

      // Advance completion state and generate events on each B response.

      if (wr_done && inf_v_q) begin
        wd_q[inf_ch_q] <= wd_q[inf_ch_q] + 32'd1;
        inf_v_q        <= 1'b0;
        if (inf_end_q) evt_end[inf_ch_q] <= 1'b1;
        if ((lvl_done_nxt >= cfg_wmark[inf_ch_q]) &&
            ((wd_q[inf_ch_q] - rptr[inf_ch_q]) < cfg_wmark[inf_ch_q]))
          evt_wmark[inf_ch_q] <= 1'b1;  // Cross the watermark from below.
      end

      // Pack accepted packets while running.
      for (int c = 0; c < N_CH; c++) begin
        if (!halt_q && !abort && take_store[c]) begin
          buf_v_q[c]   <= 1'b1;
          buf_end_q[c] <= is_end[c];
          // Capture the write address with the record.
          buf_addr_q[c] <= AW'(cfg_base[c])
                          + (AW'(wi_q[c] & (cfg_size[c] - 32'd1)) << 4);
          buf_d_q[c]   <= {ts[15:0],
                           {7'h0, is_end[c]},
                           8'(c),
                           rx_tdata[ch2port(c)]};
        end
        if (take_drop_ovf[c]) evt_ovf[c] <= 1'b1;
      end

      // Transfer the selected record to the write backend.
      if (wr_take) begin
        buf_v_q[grant_ch] <= 1'b0;
        wi_q[grant_ch]    <= wi_q[grant_ch] + 32'd1;
        inf_v_q           <= 1'b1;
        inf_ch_q          <= grant_ch;
        inf_end_q         <= buf_end_q[grant_ch];
        rr_q              <= ($clog2(N_CH))'((32'(grant_ch) + 1) % N_CH);
      end
    end
  end

  // Drain status for software double buffering, ring resizing, and task changes.
  // Pause incoming traffic while reception is disabled.
  logic [N_CH-1:0] idle_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) idle_q <= '0;
    else
      for (int c = 0; c < N_CH; c++)
        idle_q[c] <= !cfg_en[c] && !buf_v_q[c]
                     && !(inf_v_q && (32'(inf_ch_q) == c));
  assign idle = idle_q;

  assign wptr = wd_q;
  always_comb
    for (int c = 0; c < N_CH; c++)
      level[c] = 16'(wd_q[c] - rptr[c]);

endmodule
