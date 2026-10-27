// File        : tj_send_verification_top.sv
// Module      : tj_send_verification_top
// Description : Connect CSR, SEND and the AXI read backend for simulation.
module tj_send_verification_top (
  input logic pclk, presetn, maxi_clk, maxi_rstn,
  input logic psel, penable, pwrite,
  input logic [15:0] paddr,
  input logic [31:0] pwdata,
  output logic pready, pslverr,
  output logic [31:0] prdata,
  output logic arvalid,
  input logic arready,
  output logic [3:0] arid,
  output logic [47:0] araddr,
  output logic [7:0] arlen,
  output logic [2:0] arsize,
  output logic [1:0] arburst,
  input logic rvalid,
  output logic rready,
  input logic [127:0] rdata,
  input logic [1:0] rresp,
  input logic rlast,
  input logic [3:0] rid,
  output logic [3:0] irq,
  output logic [3:0] lv_tx_tvalid,
  input logic [3:0] lv_tx_tready,
  output logic [3:0][95:0] lv_tx_tdata
);
  import tj_ctrl_csr_pkg::*;
  tj_csr_i_t hwi;
  tj_csr_o_t hwo;
  logic sta_busy, sta_done_set, sta_err_set, irq_send_set, irq_axi_err_set;
  logic [31:0] sta_sent;
  logic req_valid, req_ready, rsp_valid, rsp_ready, rsp_last, rsp_err;
  logic [47:0] req_addr;
  logic [7:0] req_len;
  logic [127:0] rsp_data;
  always_comb begin
    hwi = '0;
    hwi.send_sta_busy = sta_busy;
    hwi.glb_sta_send_busy = sta_busy;
    hwi.send_sta_done_set = sta_done_set;
    hwi.send_sta_err_set = sta_err_set;
    hwi.send_sent = sta_sent;
    hwi.irq_raw_set[9] = irq_send_set;
    hwi.irq_raw_set[28] = irq_axi_err_set;
  end
  assign irq = {3'b0, |hwo.irq_sta};
  tj_ctrl_csr u_csr (.*);
  tj_send_subsys #(.AW(48), .N_CH(3), .N_PORTS(4)) u_send (
    .pclk, .presetn, .maxi_clk, .maxi_rstn,
    .db_go(hwo.send_db_go), .glb_srst(hwo.glb_ctrl_srst),
    .csr_src_lo(hwo.send_src_lo), .csr_src_hi(hwo.send_src_hi),
    .csr_cnt(hwo.send_cnt), .csr_lnk_en(hwo.lnk_en),
    .csr_remap0(hwo.lnk_remap0), .csr_remap1(hwo.lnk_remap1),
    .sta_busy, .sta_done_set, .sta_err_set, .irq_send_set, .irq_axi_err_set, .sta_sent,
    .req_valid, .req_ready, .req_addr, .req_len,
    .rsp_valid, .rsp_ready, .rsp_data, .rsp_last, .rsp_err,
    .tx_tvalid(lv_tx_tvalid), .tx_tready(lv_tx_tready), .tx_tdata(lv_tx_tdata)
  );
  tj_axi_rd_backend #(.AW(48)) u_axi (
    .clk(maxi_clk), .rst_n(maxi_rstn),
    .req_valid, .req_ready, .req_addr, .req_len,
    .rsp_valid, .rsp_ready, .rsp_data, .rsp_last, .rsp_err,
    .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
    .rvalid, .rready, .rdata, .rresp, .rlast, .rid
  );
endmodule
