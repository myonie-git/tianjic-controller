// File        : tj_axi_wr_backend.sv
// Module      : tj_axi_wr_backend
// Description : Convert 128-bit records to single-beat AXI4 writes.
// One outstanding write; completion includes successful and error B responses.
module tj_axi_wr_backend #(
  parameter int unsigned AW      = 40,
  parameter int unsigned AXI_AW  = 48,
  parameter int unsigned AXI_DW  = 128,
  parameter int unsigned AXI_IDW = 4,
  parameter logic [AXI_IDW-1:0] WR_ID = '1
)(
  input  logic                clk,
  input  logic                rst_n,
  // Record write request and response status.
  input  logic                wr_valid,
  output logic                wr_ready,
  input  logic [AW-1:0]       wr_addr,  // 16-byte-aligned address.
  input  logic [127:0]        wr_data,
  output logic                wr_err,  // One-cycle SLVERR/DECERR pulse.
  output logic                wr_done,  // One-cycle pulse for every B response.
  output logic                wr_idle,  // No outstanding write.
  // AXI4 write address, data and response channels.
  output logic                awvalid,
  input  logic                awready,
  output logic [AXI_IDW-1:0]  awid,
  output logic [AXI_AW-1:0]   awaddr,
  output logic [7:0]          awlen,
  output logic [2:0]          awsize,
  output logic [1:0]          awburst,
  output logic                wvalid,
  input  logic                wready,
  output logic [AXI_DW-1:0]   wdata,
  output logic [AXI_DW/8-1:0] wstrb,
  output logic                wlast,
  input  logic                bvalid,
  output logic                bready,
  input  logic [1:0]          bresp,
  input  logic [AXI_IDW-1:0]  bid
);
  if (AXI_DW != 128) begin : g_dw_guard
    $fatal(1, "tj_axi_wr_backend requires AXI_DW=128");
  end

  // IDLE -> ISSUE (independent AW/W handshakes) -> WAITB.
  typedef enum logic [1:0] { WB_IDLE, WB_ISSUE, WB_WAITB } st_e;
  st_e st_q;
  logic aw_done_q, w_done_q;
  logic [AXI_AW-1:0] addr_q;
  logic [127:0]      data_q;

  assign wr_ready = (st_q == WB_IDLE);

  assign awvalid = (st_q == WB_ISSUE) && !aw_done_q;
  assign awid    = WR_ID;
  assign awaddr  = addr_q;
  assign awlen   = 8'h0;
  assign awsize  = 3'($clog2(AXI_DW/8));
  assign awburst = 2'b01;
  assign wvalid  = (st_q == WB_ISSUE) && !w_done_q;
  assign wdata   = data_q;
  assign wstrb   = '1;
  assign wlast   = 1'b1;
  assign bready  = 1'b1;

  assign wr_idle = (st_q == WB_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= WB_IDLE; aw_done_q <= 1'b0; w_done_q <= 1'b0;
      addr_q <= '0; data_q <= '0;
      wr_err <= 1'b0; wr_done <= 1'b0;
    end else begin
      wr_err  <= 1'b0;
      wr_done <= 1'b0;
      unique case (st_q)
        WB_IDLE: if (wr_valid) begin
          addr_q    <= AXI_AW'(wr_addr);
          data_q    <= wr_data;
          aw_done_q <= 1'b0;
          w_done_q  <= 1'b0;
          st_q      <= WB_ISSUE;
        end
        WB_ISSUE: begin
          if (awvalid && awready) aw_done_q <= 1'b1;
          if (wvalid  && wready)  w_done_q  <= 1'b1;
          if ((aw_done_q || (awvalid && awready)) &&
              (w_done_q  || (wvalid  && wready)))
            st_q <= WB_WAITB;
        end
        WB_WAITB: if (bvalid) begin
          wr_done <= 1'b1;
          if (bresp[1]) wr_err <= 1'b1;
          st_q <= WB_IDLE;
        end
        default: st_q <= WB_IDLE;
      endcase
    end
  end
endmodule
