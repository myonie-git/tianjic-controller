// =============================================================================
// tj_mem_rd_mux.sv — tj_mem_rd_if 双主仲裁(批次 BOOT)
// -----------------------------------------------------------------------------
// A=SEND fetch(高优先,≤4 outstanding)  B=BOOT fetch64(单发,延迟不敏感)
// 单 ID 顺序返回契约下,响应按"授权队列"回路由:请求接受时押注 A/B 标签,
// 响应逐突发(rsp_last)出队。请求粒度仲裁,无抢占。
// =============================================================================
module tj_mem_rd_mux #(
  parameter int unsigned AW = 48
)(
  input  logic          clk,
  input  logic          rst_n,
  // A 口(SEND)
  input  logic          a_req_valid,
  output logic          a_req_ready,
  input  logic [AW-1:0] a_req_addr,
  input  logic [7:0]    a_req_len,
  output logic          a_rsp_valid,
  input  logic          a_rsp_ready,
  // B 口(BOOT)
  input  logic          b_req_valid,
  output logic          b_req_ready,
  input  logic [AW-1:0] b_req_addr,
  input  logic [7:0]    b_req_len,
  output logic          b_rsp_valid,
  input  logic          b_rsp_ready,
  // 合流主口(接 tj_axi_rd_backend)
  output logic          m_req_valid,
  input  logic          m_req_ready,
  output logic [AW-1:0] m_req_addr,
  output logic [7:0]    m_req_len,
  input  logic          m_rsp_valid,
  output logic          m_rsp_ready,
  input  logic [127:0]  m_rsp_data,   // 广播给 A/B(rsp_data/last/err 共享)
  input  logic          m_rsp_last,
  input  logic          m_rsp_err,
  output logic [127:0]  rsp_data,
  output logic          rsp_last,
  output logic          rsp_err
);
  // 请求仲裁(A 优先;VALID 稳定性:一旦对外拉高保持到接受)
  logic sel_b_q, sel_lock_q;
  wire  pick_b = sel_lock_q ? sel_b_q : (!a_req_valid && b_req_valid);

  assign m_req_valid = a_req_valid || b_req_valid;
  assign m_req_addr  = pick_b ? b_req_addr : a_req_addr;
  assign m_req_len   = pick_b ? b_req_len  : a_req_len;
  assign a_req_ready = m_req_ready && !pick_b;
  assign b_req_ready = m_req_ready &&  pick_b;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      sel_b_q <= 1'b0; sel_lock_q <= 1'b0;
    end else begin
      if (!sel_lock_q && m_req_valid && !m_req_ready) begin
        sel_b_q <= pick_b; sel_lock_q <= 1'b1;     // 挂起期锁定选路(payload 稳定)
      end
      if (m_req_valid && m_req_ready) sel_lock_q <= 1'b0;
    end

  // 授权队列:1bit 标签 × 8 深
  logic [7:0] tag_q;
  logic [3:0] wp_q, rp_q;
  wire push = m_req_valid && m_req_ready;
  wire pop  = m_rsp_valid && m_rsp_ready && m_rsp_last;
  wire head_b = tag_q[rp_q[2:0]];

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      tag_q <= '0; wp_q <= '0; rp_q <= '0;
    end else begin
      if (push) begin
        tag_q[wp_q[2:0]] <= pick_b;
        wp_q <= wp_q + 4'd1;
      end
      if (pop) rp_q <= rp_q + 4'd1;
    end

  // 响应回路由
  assign a_rsp_valid = m_rsp_valid && !head_b;
  assign b_rsp_valid = m_rsp_valid &&  head_b;
  assign m_rsp_ready = head_b ? b_rsp_ready : a_rsp_ready;
  assign rsp_data = m_rsp_data;
  assign rsp_last = m_rsp_last;
  assign rsp_err  = m_rsp_err;
endmodule
