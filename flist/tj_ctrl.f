// Synthesizable Controller RTL. Set TJ_CTRL_HOME to the controller directory.
${TJ_CTRL_HOME}/rtl/pkg/tj_ctrl_pkg.sv
${TJ_CTRL_HOME}/rtl/pkg/tj_ctrl_if.sv
${TJ_CTRL_HOME}/rtl/csr/tj_ctrl_csr_pkg.sv
${TJ_CTRL_HOME}/rtl/csr/tj_ctrl_csr.sv
${TJ_CTRL_HOME}/rtl/spi/tj_spi_engine.sv
${TJ_CTRL_HOME}/rtl/spi/tj_spi_subsys.sv
// Shell-level SPI-to-APB bridge.
${TJ_CTRL_HOME}/rtl/spi/tj_bypass_spi.sv
${TJ_CTRL_HOME}/rtl/common/tj_cdc.sv
${TJ_CTRL_HOME}/rtl/lnk/tj_cfgchain_master.sv
${TJ_CTRL_HOME}/rtl/dma/tj_axi_rd_backend.sv
${TJ_CTRL_HOME}/rtl/dma/tj_axi_wr_backend.sv
${TJ_CTRL_HOME}/rtl/dma/tj_mem_rd_mux.sv
${TJ_CTRL_HOME}/rtl/boot/tj_boot_engine.sv
${TJ_CTRL_HOME}/rtl/boot/tj_boot_subsys.sv
${TJ_CTRL_HOME}/rtl/dma/tj_send_fetch.sv
${TJ_CTRL_HOME}/rtl/dma/tj_send_engine.sv
${TJ_CTRL_HOME}/rtl/dma/tj_send_subsys.sv
${TJ_CTRL_HOME}/rtl/dma/tj_recv_engine.sv
${TJ_CTRL_HOME}/rtl/dma/tj_recv_subsys.sv
${TJ_CTRL_HOME}/rtl/top/tj_ctrl_top.sv
