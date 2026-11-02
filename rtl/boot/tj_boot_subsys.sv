// File        : tj_boot_subsys.sv
// Module      : tj_boot_subsys
// Description : Connect BOOT control and 64-byte memory fetches.
//               pclk: CSR and SPI transactions; maxi_clk: memory reads.
module tj_boot_subsys (
  // Clocks and active-low resets.
  input  logic         pclk,
  input  logic         presetn,
  input  logic         maxi_clk,
  input  logic         maxi_rstn,

  // CSR control and status (pclk).
  input  logic         db_go,
  input  logic         glb_srst,
  input  logic [1:0]   csr_kind,
  input  logic [4:0]   csr_die,
  input  logic [31:0]  csr_src_lo,
  input  logic [15:0]  csr_src_hi,
  input  logic [31:0]  csr_len,
  input  logic [31:0]  csr_dst,
  output logic         sta_busy,
  output logic         sta_done_set,
  output logic         sta_err_set,
  output logic [3:0]   sta_err_code,

  // Memory reads through the shared arbiter (maxi_clk).
  output logic         req_valid,
  input  logic         req_ready,
  output logic [47:0]  req_addr,
  output logic [7:0]   req_len,
  input  logic         rsp_valid,
  output logic         rsp_ready,
  input  logic [127:0] rsp_data,
  input  logic         rsp_last,
  input  logic         rsp_err,

  // Transactions to the SPI subsystem (pclk).
  output logic         cmd_valid,
  input  logic         cmd_ready,
  output logic [4:0]   die_id,
  output logic [1:0]   cmd_kind,
  output logic [31:0]  addr,
  output logic         wdat_valid,
  input  logic         wdat_ready,
  output logic [31:0]  wdat,
  input  logic         rdat_valid,
  output logic         rdat_ready,
  input  logic [31:0]  rdat,
  input  logic         done,
  input  logic         err_timeout
);
  // Internal block request and response.
  logic bf_req_tgl_w, bf_ack_tgl_w, bf_blk_err_w;
  logic [47:0] bf_blk_addr_w;
  logic [3:0][127:0] bf_blk_w;

  tj_boot_engine u_engine (
    .clk(pclk), .rst_n(presetn),
    .db_go(db_go), .srst(glb_srst),
    .cfg_kind(csr_kind), .cfg_die(csr_die),
    .cfg_src({csr_src_hi, csr_src_lo}), .cfg_len(csr_len), .cfg_dst(csr_dst),
    .busy_o(sta_busy), .done_set_o(sta_done_set),
    .err_set_o(sta_err_set), .err_code_o(sta_err_code),
    .f_req_tgl(bf_req_tgl_w), .f_ack_tgl(bf_ack_tgl_w),
    .f_blk_addr(bf_blk_addr_w), .f_blk(bf_blk_w), .f_blk_err(bf_blk_err_w),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
    .die_id(die_id), .cmd_kind(cmd_kind), .addr(addr),
    .wdat_valid(wdat_valid), .wdat_ready(wdat_ready), .wdat(wdat),
    .rdat_valid(rdat_valid), .rdat_ready(rdat_ready), .rdat(rdat),
    .done(done), .err_timeout(err_timeout)
  );

  tj_boot_fetch64 u_fetch (
    .maxi_clk(maxi_clk), .maxi_rstn(maxi_rstn),
    .req_tgl(bf_req_tgl_w), .ack_tgl(bf_ack_tgl_w),
    .blk_addr(bf_blk_addr_w), .blk(bf_blk_w), .blk_err(bf_blk_err_w),
    .req_valid(req_valid), .req_ready(req_ready),
    .req_addr(req_addr), .req_len(req_len),
    .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
    .rsp_data(rsp_data), .rsp_last(rsp_last), .rsp_err(rsp_err)
  );
endmodule
