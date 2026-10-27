// File        : tj_send_fetch.sv
// Module      : tj_send_fetch
// Description : Fetch 128-bit records into a 4 KiB FIFO for the SEND engine.
// All signals use clk; configuration is sampled on go.
module tj_send_fetch
  import tj_ctrl_pkg::*;
#(
  parameter int unsigned AW = 40
)(
  input  logic            clk,
  input  logic            rst_n,
  // Task control (maxi_clk).
  input  logic            go,           // Start pulse; issue only when idle.
  input  logic            abort,        // Abort pulse; discard records and drain reads.
  input  logic [47:0]     cfg_src,      // Byte address; 64-byte aligned, truncated to AW.
  input  logic [31:0]     cfg_cnt,      // Number of 16-byte records; zero selects an empty table.
  // No more records will enter the FIFO; buffered records may remain.
  output logic            src_done,
  output logic            src_err,  // Sticky read error; cleared by go.
  output logic            fetch_busy,
  // Memory read requests and ordered responses.
  output logic            req_valid,
  input  logic            req_ready,
  output logic [AW-1:0]   req_addr,
  output logic [7:0]      req_len,  // Number of 16-byte records: 1..64.
  input  logic            rsp_valid,
  output logic            rsp_ready,
  input  logic [127:0]    rsp_data,
  input  logic            rsp_last,
  input  logic            rsp_err,
  // Record stream to tj_send_engine.
  output logic            rec_valid,
  input  logic            rec_ready,
  output tj_rec_t         rec
);
  localparam int unsigned DEPTH   = 256;             // 4 KiB of record storage.
  localparam int unsigned PTR_W   = $clog2(DEPTH);
  localparam int unsigned MAX_REQ = 64;              // Maximum records per request.
  localparam int unsigned MAX_OST = 4;               // Maximum outstanding requests.
  localparam int unsigned CMT_W   = PTR_W + 2;

  // Active until reads and buffered records drain.
  logic             run_q;
  logic [47:0]      next_addr_q;
  logic [31:0]      rem_req_q;                       // Records not yet requested.
  logic [2:0]       ost_q;                           // Outstanding requests: 0..4.
  logic [CMT_W-1:0] committed_q;                     // Stored records plus reserved response slots.
  logic             stop_req_q;                      // Stop issuing new requests.
  logic             last_taken_q;                    // LAST stored; discard later responses.
  logic             err_q, abort_q, done_q;

  logic [127:0]     mem_q [DEPTH];
  logic [PTR_W:0]   wptr_q, rptr_q;

  logic [PTR_W:0]   level;
  assign level = wptr_q - rptr_q;
  logic fifo_empty;
  assign fifo_empty = (level == '0);

  // Limit each request to the remaining records, MAX_REQ and the 4 KiB boundary.
  logic [31:0] bound_recs;
  logic [7:0]  chunk;
  always_comb begin
    bound_recs = (32'd4096 - 32'(next_addr_q[11:0])) >> 4;
    chunk      = 8'((rem_req_q < 32'(MAX_REQ)) ? rem_req_q : 32'(MAX_REQ));
    if (32'(chunk) > bound_recs) chunk = 8'(bound_recs);
  end

  // Hold each presented request until accepted, including after LAST, error or abort.
  logic ar_pend_q;
  logic req_want;
  assign req_want  = run_q && !stop_req_q && (rem_req_q != 0)
                     && (ost_q < 3'(MAX_OST))
                     && ((32'(committed_q) + 32'(chunk)) <= 32'(DEPTH));
  assign req_valid = ar_pend_q || req_want;
  assign req_addr  = AW'(next_addr_q);
  assign req_len   = chunk;

  // Request, response and record handshakes.
  logic ev_issue, ev_rsp, ev_store, ev_disc, ev_pop;
  assign ev_issue = req_valid && req_ready;
  assign ev_rsp   = rsp_valid && rsp_ready;
  assign ev_store = ev_rsp && !err_q && !abort_q && !last_taken_q;
  // Discard the response and release its reserved slot.
  assign ev_disc  = ev_rsp && !ev_store;
  assign rsp_ready = run_q;

  assign rec_valid = run_q && !fifo_empty && !err_q && !abort_q;
  assign rec       = tj_rec_t'(mem_q[rptr_q[PTR_W-1:0]]);
  assign ev_pop    = rec_valid && rec_ready;

  logic ev_last_rec;
  assign ev_last_rec = ev_store && rsp_data[104 + FLAG_LAST];

  logic ev_err, ev_abort;
  assign ev_err   = ev_rsp && rsp_err && !err_q;
  assign ev_abort = run_q && abort && !abort_q;

  // Task state, FIFO pointers and outstanding counts.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run_q        <= 1'b0;
      next_addr_q  <= '0;
      rem_req_q    <= '0;
      ost_q        <= '0;
      committed_q  <= '0;
      stop_req_q   <= 1'b0;
      last_taken_q <= 1'b0;
      err_q        <= 1'b0;
      abort_q      <= 1'b0;
      done_q       <= 1'b0;
      wptr_q       <= '0;
      rptr_q       <= '0;
      ar_pend_q    <= 1'b0;
    end else if (go) begin
      run_q        <= 1'b1;
      next_addr_q  <= {cfg_src[47:6], 6'h0};                 // Clear the low six address bits.
      rem_req_q    <= cfg_cnt;
      ost_q        <= '0;
      committed_q  <= '0;
      stop_req_q   <= (cfg_cnt == 0);
      last_taken_q <= 1'b0;
      err_q        <= 1'b0;
      abort_q      <= 1'b0;
      done_q       <= 1'b0;
      wptr_q       <= '0;
      rptr_q       <= '0;
      ar_pend_q    <= 1'b0;
    end else if (run_q) begin
      ar_pend_q <= req_valid && !req_ready;
      if (ev_issue) begin
        next_addr_q <= next_addr_q + (48'(chunk) << 4);
        rem_req_q   <= rem_req_q - 32'(chunk);
        if (rem_req_q == 32'(chunk)) stop_req_q <= 1'b1;
      end
      if (ev_last_rec || ev_err || ev_abort) stop_req_q <= 1'b1;
      if (ev_last_rec) last_taken_q <= 1'b1;
      if (ev_err)      err_q        <= 1'b1;
      if (ev_abort)    abort_q      <= 1'b1;

      ost_q <= ost_q + 3'(ev_issue) - 3'(ev_rsp && rsp_last);

      committed_q <= committed_q
                     + (ev_issue ? CMT_W'(chunk) : '0)
                     - CMT_W'(ev_pop) - CMT_W'(ev_disc);

      if (ev_store) begin
        mem_q[wptr_q[PTR_W-1:0]] <= rsp_data;
        wptr_q <= wptr_q + 1'b1;
      end

      // Flush buffered records on error or abort, including any same-cycle write.
      if (ev_err || ev_abort) rptr_q <= wptr_q + (PTR_W+1)'(ev_store);
      else if (ev_pop)        rptr_q <= rptr_q + 1'b1;

      // Wait for pending requests and outstanding responses before marking fetch complete.
      if (!done_q && stop_req_q && (ost_q == '0) && !ev_rsp && !req_valid)
        done_q <= 1'b1;
      if (done_q && fifo_empty)
        run_q <= 1'b0;
    end
  end

  assign src_done   = done_q;
  assign src_err    = err_q;
  assign fetch_busy = run_q;

endmodule
