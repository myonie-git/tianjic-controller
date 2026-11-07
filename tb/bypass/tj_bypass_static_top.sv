// File        : tj_bypass_static_top.sv
// Module      : tj_bypass_static_top
// Description : Enable the SPI bypass for standalone lint and CDC checks.
module tj_bypass_static_top(
  input  logic              pclk,
  input  logic              presetn,

  input  logic              spi_sclk,
  input  logic              spi_mosi,
  input  logic              spi_ss_n,
  output logic              spi_miso,
  output logic              spi_miso_oe,

  input  logic              u_psel,
  input  logic              u_penable,
  input  logic              u_pwrite,
  input  logic [15:0]       u_paddr,
  input  logic [31:0]       u_pwdata,
  output logic              u_pready,
  output logic              u_pslverr,
  output logic [31:0]       u_prdata,

  output logic              d_psel,
  output logic              d_penable,
  output logic              d_pwrite,
  output logic [15:0]       d_paddr,
  output logic [31:0]       d_pwdata,
  input  logic              d_pready,
  input  logic              d_pslverr,
  input  logic [31:0]       d_prdata
);
  tj_bypass_spi #(.ENABLE_BYPASS_SPI(1'b1)) u_dut (.*);
endmodule
