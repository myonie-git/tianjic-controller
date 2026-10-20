// File        : tj_ctrl_if.sv
// Interface   : tj_rec_stream_if, tj_mem_rd_if, tj_mem_wr_if, tj_spi_txn_if,
//               tj_spi_phy_if, tj_pkt_axis_if, tj_cfgchain_if.
// Description : Internal record, memory and link interfaces.
//               Controller modules currently use explicit signal ports.
// Interfaces are single-clock; connecting modules provide CDC.
`ifndef TJ_CTRL_IF_SV
`define TJ_CTRL_IF_SV

import tj_ctrl_pkg::*;

// Record stream with valid/ready handshaking.
interface tj_rec_stream_if (input logic clk, input logic rst_n);
  logic     valid;
  logic     ready;
  tj_rec_t  rec;

  modport src (output valid, rec, input  ready);
  modport dst (input  valid, rec, output ready);
endinterface

// Memory reads: separate request and response channels, with ordered responses.
// Backend latency is variable; at least four outstanding requests are expected.
interface tj_mem_rd_if #(
  parameter int unsigned AW = 40   // Byte address width.
)(input logic clk, input logic rst_n);
  // Read request.
  logic          req_valid;
  logic          req_ready;
  logic [AW-1:0] req_addr;   // 64-byte aligned.
  logic [7:0]    req_len;    // Number of 16-byte records (1..255).
  // Ordered read response.
  logic          rsp_valid;
  logic          rsp_ready;
  logic [127:0]  rsp_data;   // One record per accepted response.
  logic          rsp_last;   // Last record of this request.
  logic          rsp_err;    // Read response error; abort the request.

  modport mst (output req_valid, req_addr, req_len, rsp_ready,
               input  req_ready, rsp_valid, rsp_data, rsp_last, rsp_err);
  modport slv (input  req_valid, req_addr, req_len, rsp_ready,
               output req_ready, rsp_valid, rsp_data, rsp_last, rsp_err);
endinterface

// Single-record writes; the backend may combine writes into bursts.
interface tj_mem_wr_if #(
  parameter int unsigned AW = 40
)(input logic clk, input logic rst_n);
  logic          wr_valid;
  logic          wr_ready;
  logic [AW-1:0] wr_addr;    // 16-byte aligned.
  logic [127:0]  wr_data;
  logic          wr_err;     // One-cycle pulse per failed write response.

  modport mst (output wr_valid, wr_addr, wr_data, input wr_ready, wr_err);
  modport slv (input  wr_valid, wr_addr, wr_data, output wr_ready, wr_err);
endinterface

// SPI transactions; the engine handles RDREQ/RD sequencing and CS timing.
interface tj_spi_txn_if (input logic clk, input logic rst_n);
  // Command.
  logic         cmd_valid;
  logic         cmd_ready;
  logic [4:0]   die_id;      // Global die index (0..N_DIE-1).
  logic [1:0]   cmd_kind;    // 0: WR1, 1: WR16, 2: RD1, 3: RD16.
  logic [31:0]  addr;        // Chip byte address, 4-byte aligned.
  // Write data: one word for WR1, sixteen words for WR16.
  logic         wdat_valid;
  logic         wdat_ready;
  logic [31:0]  wdat;
  // Read data: one word for RD1, sixteen words for RD16.
  logic         rdat_valid;
  logic         rdat_ready;
  logic [31:0]  rdat;
  // Completion and error status.
  logic         done;        // One-cycle completion pulse.
  logic         err_timeout; // Timeout pulse; recovery is software-controlled.
  // Consume all read words before done; buffered read data blocks new commands.

  modport mst (output cmd_valid, die_id, cmd_kind, addr, wdat_valid, wdat, rdat_ready,
               input  cmd_ready, wdat_ready, rdat_valid, rdat, done, err_timeout);
  modport slv (input  cmd_valid, die_id, cmd_kind, addr, wdat_valid, wdat, rdat_ready,
               output cmd_ready, wdat_ready, rdat_valid, rdat, done, err_timeout);
endinterface

// Grouped SPI clocks/data with per-die CS and MISO.
// Physical pin mapping is provided by the board wrapper.
interface tj_spi_phy_if #(
  parameter int unsigned N_DIE_P = tj_ctrl_pkg::N_DIE
)(input logic clk, input logic rst_n);
  logic [tj_ctrl_pkg::N_SPI_GRP-1:0] sclk;
  logic [tj_ctrl_pkg::N_SPI_GRP-1:0] mosi;
  logic [N_DIE_P-1:0]                cs_n;    // Active-low chip select per die.
  logic [N_DIE_P-1:0]                miso;    // Logical MISO per die.

  modport txn (output sclk, mosi, cs_n, input miso);
  modport phy (input  sclk, mosi, cs_n, output miso);
endinterface

// LVDS packet stream: one 96-bit packet per accepted transfer.
interface tj_pkt_axis_if (input logic clk, input logic rst_n);
  logic        tvalid;
  logic        tready;
  logic [95:0] tdata;

  modport src (output tvalid, tdata, input  tready);
  modport dst (input  tvalid, tdata, output tready);
endinterface

// LVDS configuration chain with readback.
// din[32] selects address/control (1) or write data (0).
interface tj_cfgchain_if (input logic clk, input logic rst_n);
  logic [32:0] din;       // To the instance's din_pre port.
  logic        din_vld;
  logic [31:0] dout;      // Readback from the instance's dout_pre port.
  logic        dout_vld;

  modport mst (output din, din_vld, input  dout, dout_vld);
  modport ins (input  din, din_vld, output dout, dout_vld);
endinterface

`endif // TJ_CTRL_IF_SV
