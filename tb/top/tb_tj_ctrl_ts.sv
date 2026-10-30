`timescale 1ns/1ps
// File        : tb_tj_ctrl_ts.sv
// Module      : tb_tj_ctrl_ts
// Description : APB control and timestamp snapshot checks through public top ports.
// CASE: 0 control routing, 1 continuous snapshots, 2 prescalers and reset controls.
module tb_tj_ctrl_ts;
  real php=5.0,mhp=1.2;
  initial begin
    void'($value$plusargs("TJ_PCLK_HP=%f",php));
    void'($value$plusargs("TJ_MAXI_HP=%f",mhp));
  end
  logic pclk=0,maxi_clk=0,presetn=0,maxi_rstn=0;
  always #(php) pclk=~pclk;
  always #(mhp) maxi_clk=~maxi_clk;
  logic psel=0,penable=0,pwrite=0,pready,pslverr;
  logic [15:0] paddr=0;
  logic [31:0] pwdata=0,prdata,chip_rst_n;
  logic [3:0] irq,clkctl;
  logic uart_tx,axis_ready,axis_valid;
  logic [32:0] cfg_din;
  logic cfg_vld,cfg_rsp_vld=0,cfg_pending=0;
  logic [31:0] cfg_rsp=32'hC0DEC0DE;
  tj_ctrl_top dut (
    .pclk,.presetn,.maxi_clk,.maxi_rstn,.psel,.penable,.pwrite,.paddr,.pwdata,.pready,.pslverr,.prdata,
    .awvalid(),.awready(1'b0),.awid(),.awaddr(),.awuser(),.awlen(),.awsize(),.awburst(),
    .wvalid(),.wready(1'b0),.wdata(),.wstrb(),.wlast(),.bvalid(1'b0),.bready(),.bresp(2'b0),.bid('0),
    .arvalid(),.arready(1'b0),.arid(),.araddr(),.aruser(),.arlen(),.arsize(),.arburst(),
    .rvalid(1'b0),.rready(),.rdata('0),.rresp(2'b0),.rlast(1'b0),.rid('0),
    .s_axis_pk_tvalid(1'b0),.s_axis_pk_tready(axis_ready),.s_axis_pk_tdata('0),.s_axis_pk_tlast(1'b0),
    .m_axis_pk_tvalid(axis_valid),.m_axis_pk_tready(1'b1),.m_axis_pk_tdata(),.m_axis_pk_tlast(),
    .irq,.lv_tx_tvalid(),.lv_tx_tready('1),.lv_tx_tdata(),.lv_rx_tvalid('0),.lv_rx_tready(),.lv_rx_tdata('0),
    .lvcfg_din(cfg_din),.lvcfg_din_vld(cfg_vld),.lvcfg_dout(cfg_rsp),.lvcfg_dout_vld(cfg_rsp_vld),
    .spi_sclk(),.spi_mosi(),.spi_cs_n(),.spi_miso('0),.chip_rst_n,.clkctl,.uart_rx(1'b1),.uart_tx);
  always @(posedge pclk) begin
    if(!presetn)begin cfg_rsp_vld<=0;cfg_pending<=0;end
    else begin
      cfg_pending<=cfg_vld&&cfg_din[32]&&!cfg_din[25];
      cfg_rsp_vld<=cfg_pending;
    end
  end
  int checks=0,errs=0,scenario=0;
  task automatic chk(input bit ok,input string msg);
    checks++;
    if(!ok)begin errs++;if(errs<=12)$display("FAIL: %s @%0t",msg,$time);end
  endtask
  task automatic transfer(input bit wr,input logic[15:0] addr,input logic[31:0] data,
                           output logic[31:0] rd,input bit expect_error=0);
    int guard;
    @(negedge pclk);psel=1;penable=0;pwrite=wr;paddr=addr;pwdata=data;
    @(negedge pclk);penable=1;
    guard=0;
    @(posedge pclk);
    while(!pready && guard<10000)begin guard++;@(posedge pclk);end
    chk(guard<10000,"APB completes");
    chk(pslverr===expect_error,$sformatf("APB error at %h",addr));
    rd=prdata;
    @(negedge pclk);psel=0;penable=0;
  endtask
  task automatic wr(input logic[15:0] addr,input logic[31:0] data);
    logic[31:0] unused;transfer(1,addr,data,unused);
  endtask
  task automatic rd(input logic[15:0] addr,output logic[31:0] data);
    transfer(0,addr,0,data);
  endtask
  task automatic settle;
    repeat(16)@(negedge maxi_clk);repeat(8)@(negedge pclk);
  endtask
  logic[31:0] a,b,hi1,hi2,prev;
  int divn,expected,bitno;
  realtime t0,t1;
  initial begin
    void'($value$plusargs("CASE=%d",scenario));
    $display("CTRL TOP CASE=%0d pclk_half=%f maxi_half=%f",scenario,php,mhp);
    #200ns;@(negedge pclk);presetn=1;maxi_rstn=1;settle();
    if(scenario==0)begin
      chk(chip_rst_n==0 && clkctl==0 && uart_tx==1,"reset pin defaults");
      chk(axis_ready && !axis_valid,"reserved AXIS defaults");
      rd(16'h0,a);chk(a==32'h544A4331,"controller identification");
      wr(16'h8,32'h89ABCDEF);rd(16'h8,a);chk(a==32'h89ABCDEF,"APB scratch write/read");
      transfer(0,16'h4000,0,a,1);
      rd(16'h8,a);chk(a==32'h89ABCDEF,"SPIWIN decode preserves CSR scratch");
      wr(16'h200,32'hA55A3CC3);wr(16'h204,32'hB);
      chk(chip_rst_n==32'hA55A3CC3 && clkctl==4'hB,"system pin outputs follow CSR");
      for(int i=0;i<4;i++)begin
        bitno=i==0?0:i==1?13:i==2?24:31;
        wr(16'h100,32'hFFFFFFFF);wr(16'h104,32'(1)<<bitno);
        wr(16'h10C,32'(1)<<bitno);
        chk(irq==(4'(1)<<i),$sformatf("IRQ class %0d",i));
        wr(16'h100,32'hFFFFFFFF);chk(irq==0,"IRQ clear");
      end
      wr(16'h104,32'h400);wr(16'h3800,2);wr(16'h3804,32'h123);wr(16'h380C,1);
      for(int k=0;k<100;k++)begin rd(16'h3810,a);if(a[8])break;end
      chk(a[8],"CC read completion reaches CSR");rd(16'h3808,a);chk(a==cfg_rsp,"CC read data");
      rd(16'h100,a);chk(a[10] && irq[0],"CC event reaches IRQ.RAW and irq0");
    end else if(scenario==2)begin
      for(int sel=0;sel<4;sel++)begin
        divn=sel==0?1:sel==1?16:sel==2?100:1000;
        wr(16'h208,32'h100|(sel<<1));
        repeat(64)@(negedge maxi_clk);repeat(32)@(negedge pclk);
        rd(16'h20C,a);chk(a==0,"clear reaches stable zero");
        wr(16'h208,1|(sel<<1));t0=$realtime;
        repeat(divn*128)@(negedge maxi_clk);
        wr(16'h208,sel<<1);t1=$realtime;
        repeat(64)@(negedge maxi_clk);repeat(32)@(negedge pclk);
        rd(16'h20C,a);
        expected=$rtoi((t1-t0)/(2*mhp*divn));
        chk(a+4>=expected && a<=expected+4,$sformatf("stopped /%0d count=%0d expected~%0d",divn,a,expected));
        rd(16'h210,b);chk(b==0,"high timestamp bits remain zero");
        repeat(80)@(negedge maxi_clk);rd(16'h20C,b);chk(a==b,"stopped timestamp remains stable");
        wr(16'h000C,1);repeat(64)@(negedge maxi_clk);repeat(32)@(negedge pclk);
        rd(16'h20C,b);chk(a==b,"GLB SRST does not clear timestamp");
        wr(16'h208,32'h100);rd(16'h20C,b);
        $display("CLR_FIRST_READ prescaler=%0d value=%0d",divn,b);
        repeat(64)@(negedge maxi_clk);repeat(32)@(negedge pclk);
        rd(16'h20C,b);chk(b==0,"clear eventually becomes visible after CDC and snapshot");
      end
    end else begin
      wr(16'h208,32'h100);settle();wr(16'h208,1);settle();prev=0;
      for(int n=0;n<1500;n++)begin
        rd(16'h210,hi1);rd(16'h20C,a);rd(16'h210,hi2);
        chk(hi1==0 && hi2==0,"timestamp high halves do not wrap in this test");
        if(hi1==hi2)begin
          chk(a>=prev,$sformatf("HI/LO/HI accepted backwards time %0d -> %0d",prev,a));prev=a;
        end
      end
      wr(16'h208,0);settle();rd(16'h20C,a);repeat(20)@(negedge maxi_clk);rd(16'h20C,b);
      chk(a==b,"stopped timestamp is stable positive control");
    end
    if(errs==0 && checks>0)$display("CTRL TOP TB PASS (%0d checks)",checks);
    else $display("CTRL TOP TB FAIL case=%0d (%0d/%0d)",scenario,errs,checks);
    $finish;
  end
  initial begin #10ms;$fatal(1,"CTRL TOP TIMEOUT");end
endmodule
