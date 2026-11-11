// File        : tb_tj_spi_profile.sv
// Module      : tb_tj_spi_profile
// Description : Exercise all 32 dies through doorbells, SPIWIN and BOOT.
`timescale 1ns/1ps
// Independent wire-level slave: captures commands/addresses/data and returns a
// distinct value for every die. Exercises shared upstream logic in both profiles.
module tj_spi_profile_slave #(parameter int DIE=0)(
 input wire sclk,mosi,cs_n,output wire miso,
 output logic [31:0] last_write,output integer writes
);
 logic [71:0] frame;
 integer count;
 wire [31:0] reply=32'hcafe0000 | DIE;
 assign miso=(!cs_n && count>=40 && count<72) ? reply[71-count] : 1'b0;
 initial begin frame=0;count=0;writes=0;last_write=0;end
 always @(negedge cs_n) begin frame=0;count=0;end
 always @(posedge sclk) if(!cs_n) begin frame={frame[70:0],mosi};count=count+1;end
 always @(posedge cs_n) if(count==72 && frame[71:64]==8'h00) begin
   if(frame[63:32]!==32'h1000+4*DIE)$fatal(1,"SPI address die%0d",DIE);
   last_write=frame[31:0];writes=writes+1;
 end
endmodule

module tb_tj_spi_profile;
 import tj_ctrl_pkg::*;
 import tj_ctrl_csr_pkg::*;
 localparam int N_SPI_GRP = TJ_CSR_SPI_N;
 localparam int N_SPI_DIES_PER_GRP = 32 / N_SPI_GRP;
 localparam int SPI_DIE_SEL_W = $clog2(N_SPI_DIES_PER_GRP);
 int checks=0;
 logic pclk=0,presetn=0;
 always #5 pclk=~pclk;
 tj_csr_o_t hwo;
 wire [N_SPI_GRP-1:0][31:0] spi_rdata_o;
 wire [N_SPI_GRP-1:0] spi_busy_o,eng_busy_o,spi_done_set_o,spi_err_set_o;
 wire spiwin_busy_o,spiwin_err_set_o;
 logic win_psel=0,win_penable=0,win_pwrite=0;
 logic [11:0] win_paddr=0;
 logic [31:0] win_pwdata=0;
 wire win_pready,win_pslverr;
 wire [31:0] win_prdata;
 logic bt_cmd_valid=0,bt_wdat_valid=0,bt_rdat_ready=1;
 wire bt_cmd_ready,bt_wdat_ready,bt_rdat_valid,bt_done,bt_err;
 logic [4:0] bt_die=0;
 logic [1:0] bt_kind=0;
 logic [31:0] bt_addr=0,bt_wdat=0;
 wire [31:0] bt_rdat;
 wire [N_SPI_GRP-1:0] spi_sclk,spi_mosi;
 wire [31:0] spi_cs_n,spi_miso;
 wire [31:0][31:0] last_write;
 wire [31:0] writes[32];
 tj_spi_subsys dut(.*);
 for(genvar d=0;d<32;d++) begin : slave
   tj_spi_profile_slave #(.DIE(d)) model(.sclk(spi_sclk[d/N_SPI_DIES_PER_GRP]),
     .mosi(spi_mosi[d/N_SPI_DIES_PER_GRP]),.cs_n(spi_cs_n[d]),
     .miso(spi_miso[d]),.last_write(last_write[d]),.writes(writes[d]));
 end
 task automatic doorbell(input int die,input bit read_cmd);
   int group_id;
   group_id=die/N_SPI_DIES_PER_GRP;
   @(negedge pclk);
   hwo.spi_cmd_kind[group_id]=read_cmd ? 1 : 0;
   hwo.spi_cmd_die[group_id]=SPI_DIE_SEL_W'(die%N_SPI_DIES_PER_GRP);
   hwo.spi_addr[group_id]='h1000+4*die;
   hwo.spi_wdata[group_id]='h12340000+die;
   hwo.spi_db_go[group_id]=1;
   @(negedge pclk);hwo.spi_db_go[group_id]=0;
   do @(negedge pclk);while(!spi_done_set_o[group_id] && !spi_err_set_o[group_id]);
   if(spi_err_set_o[group_id])$fatal(1,"SPI timeout die%0d",die);
   if(read_cmd && spi_rdata_o[group_id]!==('hcafe0000|die))$fatal(1,"SPI read die%0d data%h",die,spi_rdata_o[group_id]);
   if(!read_cmd && last_write[die]!==('h12340000+die))$fatal(1,"SPI write die%0d",die);
   checks++;
   repeat(5)@(negedge pclk);
 endtask
 task automatic window_read(input int die);
   @(negedge pclk);
   hwo.spiwin_ctrl_en=1;hwo.spiwin_page_die=5'(die);hwo.spiwin_offs=1;
   win_psel=1;win_pwrite=0;win_paddr=12'(4*die);
   @(negedge pclk);win_penable=1;
   do @(negedge pclk);while(!win_pready);
   if(win_pslverr || win_prdata!==('hcafe0000|die))$fatal(1,"SPI window die%0d",die);
   win_psel=0;win_penable=0;
   checks++;
   repeat(5)@(negedge pclk);
 endtask
 task automatic boot_write(input int die);
   @(negedge pclk);bt_die=5'(die);bt_kind=0;bt_addr='h1000+4*die;
   bt_wdat='hbeef0000+die;bt_cmd_valid=1;
   do @(posedge pclk);while(!bt_cmd_ready);
   @(negedge pclk);bt_cmd_valid=0;bt_wdat_valid=1;
   do @(posedge pclk);while(!bt_wdat_ready);
   @(negedge pclk);bt_wdat_valid=0;
   do @(negedge pclk);while(!bt_done && !bt_err);
   if(bt_err || last_write[die]!==('hbeef0000+die))$fatal(1,"BOOT SPI route die%0d",die);
   checks++;
   repeat(5)@(negedge pclk);
 endtask
 initial begin
   hwo='0;
   for(int g=0;g<N_SPI_GRP;g++)begin hwo.spi_clkdiv[g]=1;hwo.spi_tmo[g]=10000;end
   repeat(5)@(negedge pclk);presetn=1;
   for(int d=0;d<32;d++)begin doorbell(d,0);doorbell(d,1);window_read(d);boot_write(d);end
   for(int d=0;d<32;d++)begin
     if(writes[d]!=2)$fatal(1,"CS isolation die%0d writes%0d",d,writes[d]);
     checks++;
   end
   $display("SPI PROFILE TB PASS (%0d checks)",checks);$finish;
 end
 initial begin #10ms;$fatal(1,"SPI watchdog");end
endmodule
