// File        : tj_axi_rd_backend.sv
// Module      : tj_axi_rd_backend
// Description : Map record read requests and responses to AXI4 AR/R.
//               128-bit data, fixed ID, INCR bursts.
module tj_axi_rd_backend #(
  parameter int unsigned AW      = 40,
  parameter int unsigned AXI_AW  = 48,
  parameter int unsigned AXI_DW  = 128,
  parameter int unsigned AXI_IDW = 4,
  parameter logic [AXI_IDW-1:0] RD_ID = '0
)(
  input  logic                clk,
  input  logic                rst_n,
  // Internal read requests and responses.
  // Caller aligns addresses to 64 bytes and splits bursts at 4 KiB boundaries.
  input  logic                req_valid,
  output logic                req_ready,
  input  logic [AW-1:0]       req_addr,
  input  logic [7:0]          req_len,     // 16-byte records: 1..255 (fetch: 1..64); 0 invalid.
  output logic                rsp_valid,
  input  logic                rsp_ready,
  output logic [127:0]        rsp_data,
  output logic                rsp_last,
  output logic                rsp_err,
  // AXI4 read address and data channels.
  output logic                arvalid,
  input  logic                arready,
  output logic [AXI_IDW-1:0]  arid,
  output logic [AXI_AW-1:0]   araddr,
  output logic [7:0]          arlen,
  output logic [2:0]          arsize,
  output logic [1:0]          arburst,
  input  logic                rvalid,
  output logic                rready,
  input  logic [AXI_DW-1:0]   rdata,
  input  logic [1:0]          rresp,
  input  logic                rlast,
  input  logic [AXI_IDW-1:0]  rid
);
  if (AXI_DW != 128) begin : g_dw_guard
    $fatal(1, "tj_axi_rd_backend requires AXI_DW=128");
  end

  // Read address channel.
  assign arvalid  = req_valid;
  assign req_ready = arready;
  assign arid     = RD_ID;
  assign araddr   = AXI_AW'(req_addr);
  assign arlen    = req_len - 8'd1;      // AXI encodes the beat count minus one.
  assign arsize   = 3'($clog2(AXI_DW/8));
  assign arburst  = 2'b01;               // INCR
  // Read responses use RD_ID and preserve request order.
  assign rsp_valid = rvalid;
  assign rready    = rsp_ready;
  assign rsp_data  = rdata;
  assign rsp_last  = rlast;
  assign rsp_err   = rresp[1];           // SLVERR or DECERR.
endmodule
