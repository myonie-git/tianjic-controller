// File        : tj_ctrl_pkg.sv
// Package     : tj_ctrl_pkg
// Description : Common constants and data types for the Tianjic controller.
//               Covers channel counts, packet formats, SPI definitions and chip addresses.

`ifndef TJ_CTRL_PKG_SV
`define TJ_CTRL_PKG_SV

package tj_ctrl_pkg;

  // Channel and device counts
  localparam int unsigned N_CH_MAX     = 16;  // Channel IDs 0..11: west side; 12..15: reserved.
  localparam int unsigned N_CH_WEST    = 12;  // Unused by controller RTL; 4 die rows x 3 groups.
  localparam int unsigned N_CH_V1      = 3;   // v1 channels: G0..G2 on die (0,0).
  localparam int unsigned N_LVDS_PORTS = 4;   // Logical AXIS ports per lvds_subsys instance.
  localparam int unsigned N_SPI_GRP    = 8;   // SPI bus groups.
  localparam int unsigned N_DIE        = 32;  // Board total: 2 chips x 16 dies per chip.
  localparam int unsigned N_RST        = 32;  // One reset control per die.

  // NoC packet (LVDS): 64-bit payload + 32-bit header.
  localparam int unsigned NOC_PKT_W = 96;

  typedef struct packed {
    logic [63:0] data;   // [95:32] Payload.
    logic [13:0] addr;   // [31:18] Destination offset: 8B units in 8B mode; bytes in 1B mode.
    logic [5:0]  dx;     // [17:12] Signed X offset; positive east.
    logic [5:0]  dy;     // [11:6]  Signed Y offset; positive south.
    logic [1:0]  lvds;   // [5:4]   Destination edge port in all2all mode.
    logic [3:0]  ptype;  // [3:0]   Packet type.
  } tj_noc_pkt_t;

  // Packet type encodings.
  localparam logic [3:0] PTYPE_DATA8 = 4'b0010;  // 8-byte data write.
  localparam logic [3:0] PTYPE_END   = 4'b0100;  // TX END; data[14:0] = end_pkt_cnt.

  // 16-byte TX/RX record.
  localparam int unsigned REC_W = 128;

  typedef struct packed {
    logic [15:0] tag;    // [127:112] TX: software tag; RX: timestamp[15:0].
    logic [7:0]  flags;  // [111:104] Direction-specific flags.
    logic [7:0]  ch;     // [103:96]  Logical channel ID.
    logic [95:0] pkt;    // [95:0]    Unmodified NoC packet.
  } tj_rec_t;

  // TX flag bit positions.
  localparam int unsigned FLAG_LAST  = 0;  // Last record in the block.
  localparam int unsigned FLAG_FENCE = 1;  // Wait for prior TX records to be accepted.
  localparam int unsigned FLAG_IRQ   = 2;  // Request a TX interrupt.
  // RX flags: bit 0 marks END packets; other bits are zero.

  // SPI commands for spi2ahb.
  // Mode 0, MSB first; hold CS low for each frame.
  // Reads: request, wait for completion, then fetch at the same address.
  localparam logic [7:0] SPI_CMD_WR1     = 8'h00;  // Write one 32-bit word.
  localparam logic [7:0] SPI_CMD_WR16    = 8'h01;  // Write exactly 16 x 32-bit words.
  localparam logic [7:0] SPI_CMD_RDREQ   = 8'h06;  // Request a 32-bit read.
  localparam logic [7:0] SPI_CMD_RD1     = 8'h04;  // Fetch the requested 32-bit word.
  localparam logic [7:0] SPI_CMD_RDREQ16 = 8'h07;  // Request a 16-word read.
  localparam logic [7:0] SPI_CMD_RD16    = 8'h05;  // Fetch the requested 16 words.

  localparam int unsigned SPI_PCLK_MAX_HZ = 250_000_000;  // Upper pclk bound for delay conversion.

  // SPI delays in pclk cycles; pclk must not exceed SPI_PCLK_MAX_HZ.
  localparam int unsigned SPI_CS_SETUP_CYC = 6;  // CS assertion to first SCLK edge: >= 20 ns.
  localparam int unsigned SPI_CS_HOLD_CYC  = 14; // Last SCLK edge to CS release: >= 50 ns.
  localparam int unsigned SPI_CS_GAP_CYC   = 11; // CS high between frames: >= 40 ns.
  localparam int unsigned SPI_BLKDRAIN_GAP_CYC = 256; // WR16/RDREQ16 completion gap: >= 1 us.
  // SCLK = pclk / (2 * (DIV + 1)); software must select DIV for SCLK <= 25 MHz.
  localparam int unsigned SPI_CLKDIV_MIN   = 1;  // Minimum supported divider setting.

  localparam int unsigned SPI_SCLK_MAX_HZ = 25_000_000;  // Chip-side SCLK limit.

  // Counter delays at SPI_PCLK_MAX_HZ, excluding state-machine overhead.
  // Protocol timing requirements remain documented beside the cycle constants.
  localparam int unsigned SPI_CS_SETUP_NS =
      int'((64'd1_000_000_000 * SPI_CS_SETUP_CYC) / 64'(SPI_PCLK_MAX_HZ));
  localparam int unsigned SPI_CS_HOLD_NS =
      int'((64'd1_000_000_000 * SPI_CS_HOLD_CYC) / 64'(SPI_PCLK_MAX_HZ));
  localparam int unsigned SPI_CS_GAP_NS =
      int'((64'd1_000_000_000 * SPI_CS_GAP_CYC) / 64'(SPI_PCLK_MAX_HZ));
  localparam int unsigned SPI_BURST_GAP_NS =
      int'((64'd1_000_000_000 * SPI_BLKDRAIN_GAP_CYC) / 64'(SPI_PCLK_MAX_HZ));

  // Chip address map (per die, byte-addressed).
  localparam logic [31:0] CHIP_SRAM_BASE     = 32'h0100_0000;  // 64 KiB MCU SRAM; firmware/mailbox.
  localparam logic [31:0] CHIP_APB_BASE      = 32'h0110_0000;  // Peripheral registers.
  localparam logic [31:0] CHIP_CORE_CFG_BASE = 32'h0200_0000;  // Core configuration space.

  // SMU registers.
  localparam logic [31:0] CHIP_SMU_BASE     = CHIP_APB_BASE;
  localparam logic [31:0] CHIP_SMU_XPLL_DIV = CHIP_SMU_BASE + 32'h0C;  // XPLL divider register.
  localparam logic [31:0] CHIP_SMU_CPUBASE  = CHIP_SMU_BASE + 32'h1C;  // MCU reset vector.

  // LVDS configuration.
  localparam logic [31:0] CHIP_LVDS_CFG_BASE = CHIP_APB_BASE + 32'h0006_0000;
  localparam logic [31:0] CHIP_LVDS_CFG_CTRL = CHIP_LVDS_CFG_BASE + 32'h400;  // Enable/broadcast.
  localparam logic [31:0] CHIP_LVDS_SIDE_SEL = CHIP_LVDS_CFG_CTRL + 32'h0C;   // W0/S1/E2/N3.

  // Core memory, registers and configuration control.
  localparam logic [31:0] CHIP_CORE_MEM_BASE = CHIP_CORE_CFG_BASE;
  localparam logic [31:0] CHIP_CORE_REG_BASE = CHIP_CORE_CFG_BASE + 32'h0008_0000;
  localparam logic [31:0] CHIP_CFG_CTRL_BASE = CHIP_CORE_CFG_BASE + 32'h00FF_F000;
  localparam logic [31:0] CHIP_CFG_CORE_SEL  = CHIP_CFG_CTRL_BASE + 32'h0C;  // Target core.
  localparam logic [31:0] CHIP_CFG_RD_ST     = CHIP_CFG_CTRL_BASE + 32'h08;  // bit1: rd_done (W1C).
  localparam logic [31:0] CHIP_CFG_RD_DATA   = CHIP_CFG_CTRL_BASE + 32'h10;  // Readback data.

  // XPLL: 100 MHz reference, FRAC=0; {reserved, postdiv2, postdiv1, refdiv, fbdiv}.
  localparam logic [31:0] CHIP_XPLL_600M_VAL = {8'd0, 3'd1, 3'd2, 6'd2, 12'd24};

  // Core register byte offsets from CHIP_CORE_REG_BASE.
  localparam logic [7:0] CORE_REG_SOFT_RST  = 8'h00;  // RW: bit 0, 0=reset, 1=release.
  localparam logic [7:0] CORE_REG_START     = 8'h04;  // RW: bit 0, write 1 then 0 to start.
  localparam logic [7:0] CORE_REG_CONFIG    = 8'h08;  // RW: program base, mode and config enable.
  localparam logic [7:0] CORE_REG_CLK_SHIFT = 8'h0C;  // RW: bit 0, 1=cfg_clk for core memory.
  localparam logic [7:0] CORE_REG_LS        = 8'h10;  // RW: memory sleep and auto sleep control.
  localparam logic [7:0] CORE_REG_PC        = 8'h14;  // RO: current program counter.
  localparam logic [7:0] CORE_REG_IDLE      = 8'h18;  // RO: bit 0, 1=idle, 0=running.
  localparam logic [7:0] CORE_REG_CLK_GATE  = 8'h1C;  // RW: clock gating for Dendrite/Soma/Move.
  localparam logic [7:0] CORE_REG_IDLE_CNT  = 8'h20;  // RO: cycles in the latest idle=0 interval.

  // Timestamp width and prescaler encodings (maxi_clk).
  localparam int unsigned TS_W = 48;
  typedef enum logic [1:0] {
    TS_DIV_1   = 2'd0,  // 1 maxi_clk cycle per tick.
    TS_DIV_16  = 2'd1,  // 16 maxi_clk cycles per tick.
    TS_DIV_100 = 2'd2,  // 100 maxi_clk cycles per tick.
    TS_DIV_1K  = 2'd3   // 1000 maxi_clk cycles per tick.
  } tj_ts_div_e;

  // Deprecated: unused engine IDs; not CSR status or interrupt bit positions.
  // See controller/csr/tj_ctrl_csr.yaml for register bit assignments.
  typedef enum logic [3:0] {
    ENG_SPI0 = 4'd0,  // SPI engines 0..7; groups run independently.
    ENG_SPI7 = 4'd7,
    ENG_SEND = 4'd8,  // Downlink replay.
    ENG_RECV = 4'd9,  // Uplink collection with per-channel state.
    ENG_BOOT = 4'd10, // BOOT_PRIM / FW_LOAD / MBOX_POLL.
    ENG_LNK  = 4'd11, // LNK_CFG / CALIB / PRBS.
    ENG_SYS  = 4'd12  // Reset, clock, snapshot and trace.
  } tj_eng_e;

endpackage

`endif // TJ_CTRL_PKG_SV
