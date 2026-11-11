// File        : tb_tj_spi_profile_invalid.sv
// Module      : tb_tj_spi_profile_invalid
// Description : Deliberately mismatch top and CSR SPI dimensions; elaboration must fail.
module tb_tj_spi_profile_invalid;
  import tj_ctrl_csr_pkg::*;
  tj_ctrl_top #(.N_SPI_GRP(TJ_CSR_SPI_N == 8 ? 4 : 8)) dut();
  initial begin
    #1;
    $fatal(1, "SPI profile mismatch was not rejected");
  end
endmodule
