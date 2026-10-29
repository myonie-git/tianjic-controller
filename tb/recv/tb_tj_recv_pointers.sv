// File        : tb_tj_recv_pointers.sv
// Module      : tb_tj_recv_pointers
// Description : Check coherent write progress and host read-pointer updates.
`timescale 1ns/1ps
module tb_tj_recv_pointers;
  real pclk_hp=5.0, maxi_hp=1.2;
  initial begin
    void'($value$plusargs("TJ_PCLK_HP=%f",pclk_hp));
    void'($value$plusargs("TJ_MAXI_HP=%f",maxi_hp));
  end
  logic pclk=0,maxi_clk=0,presetn=0,maxi_rstn=0;
  always #(pclk_hp) pclk=~pclk;
  always #(maxi_hp) maxi_clk=~maxi_clk;
  logic [2:0][31:0] csr_ring_lo,csr_size,csr_wmark,csr_rptr;
  logic [2:0][15:0] csr_ring_hi;
  logic [2:0] csr_en,csr_pol;
  logic [2:0][31:0] sta_wptr;
  logic [2:0][15:0] sta_level;
  logic [2:0] set_wmark,set_end,set_ovf;
  logic set_axi_werr;
  logic [3:0] rx_tvalid=0,rx_tready;
  logic [3:0][95:0] rx_tdata=0;
  logic wr_valid,wr_ready,wr_done=0,wr_idle;
  logic [47:0] wr_addr;
  logic [127:0] wr_data;
  tj_recv_subsys #(.AW(48)) dut (
    .pclk,.presetn,.glb_srst(1'b0),.csr_ring_lo,.csr_ring_hi,.csr_size,.csr_wmark,
    .csr_en,.csr_pol,.csr_rptr,.csr_remap0(32'h76543210),.csr_remap1(16'hBA98),
    .sta_wptr,.sta_level,.set_wmark,.set_end,.set_ovf,.set_axi_werr,
    .maxi_clk,.maxi_rstn,.ts(48'b0),.rx_tvalid,.rx_tready,.rx_tdata,
    .wr_valid,.wr_ready,.wr_addr,.wr_data,.wr_done,.wr_idle,.wr_err(1'b0)
  );

  int checks=0,errs=0,completed=0,delay_count=0;
  bit pending=0,watch_progress=0;
  int unsigned previous_wp=0;
  logic [47:0] pending_addr,seen_addr[128];
  logic [127:0] pending_data,seen_data[128];
  assign wr_ready=maxi_rstn && !pending;
  assign wr_idle=!pending;
  task automatic chk(input bit ok,input string msg);
    checks++;
    if(!ok)begin errs++;if(errs<=20)$display("FAIL: %s @%0t",msg,$time);end
  endtask
  function automatic logic [95:0] packet(input int id);
    return {32'h12345678,32'(id),32'h01234562};
  endfunction

  // Model the public record-write interface, with one outstanding completion.
  always @(posedge maxi_clk) begin
    if(!maxi_rstn)begin
      pending<=0;completed<=0;delay_count<=0;wr_done<=0;
    end else begin
      wr_done<=0;
      if(wr_valid && wr_ready)begin
        pending_addr<=wr_addr;pending_data<=wr_data;pending<=1;delay_count<=0;
      end
      if(pending)begin
        if(delay_count==3)begin
          seen_addr[completed]=pending_addr;seen_data[completed]=pending_data;
          completed<=completed+1;wr_done<=1;pending<=0;
        end else delay_count<=delay_count+1;
      end
    end
  end
  always @(posedge pclk) if(presetn && watch_progress)begin
    chk(sta_wptr[0]<=completed,"WPTR must not exceed completed writes");
    chk(sta_wptr[0]>=previous_wp,"WPTR must not go backwards before counter wrap");
    chk(sta_level[0]==16'(sta_wptr[0]-csr_rptr[0]),"LEVEL matches visible WPTR and RPTR");
    previous_wp=sta_wptr[0];
  end
  task automatic settle;
    repeat(16)@(negedge maxi_clk);
    repeat(8)@(negedge pclk);
  endtask
  task automatic configure(input int size,input bit policy);
    watch_progress=0;
    @(negedge pclk);presetn=0;maxi_rstn=0;csr_en=0;csr_rptr=0;rx_tvalid=0;
    csr_ring_hi=0;csr_pol={3{policy}};
    for(int c=0;c<3;c++)begin
      csr_ring_lo[c]=32'h20000000+32'(c*'h100000);csr_size[c]=size;csr_wmark[c]=size;
    end
    repeat(4)@(negedge pclk);presetn=1;maxi_rstn=1;
    settle();@(posedge pclk);csr_en<=1;settle();
  endtask
  task automatic send_packet(input int id);
    @(negedge maxi_clk);rx_tvalid[0]=1;rx_tdata[0]=packet(id);
    @(posedge maxi_clk);while(!rx_tready[0])@(posedge maxi_clk);
    @(negedge maxi_clk);rx_tvalid[0]=0;
  endtask
  task automatic wait_completed(input int target);
    for(int n=0;n<1000 && completed<target;n++)@(negedge maxi_clk);
    chk(completed==target,$sformatf("completed=%0d expected=%0d",completed,target));
  endtask

  initial begin
    $display("RECV POINTERS pclk_hp=%0f maxi_hp=%0f",pclk_hp,maxi_hp);
    // P1: Check progress continuously across binary carry transitions.
    configure(128,1);
    previous_wp=0;watch_progress=1;
    for(int n=0;n<80;n++)send_packet(n);
    wait_completed(80);settle();watch_progress=0;
    chk(sta_wptr[0]==80 && sta_level[0]==80,"quiescent final progress is exact");
    for(int n=0;n<80;n++)begin
      chk(seen_data[n][95:0]===packet(n),"all progress-test records preserved");
      chk(seen_addr[n]==48'h20000000+48'(n*16),"progress-test record address");
    end
    $display("P1 complete (%0d checks, %0d errors)",checks,errs);

    // P2: RPTR 3->4 changes several bits; both values leave room for two new records.
    for(int round=0;round<32;round++)begin
      configure(8,0);
      for(int n=0;n<8;n++)send_packet(round*16+n);
      wait_completed(8);settle();
      @(posedge pclk);csr_rptr[0]<=3;settle();
      chk(rx_tready[0],"host consumption releases space");
      @(posedge pclk);csr_rptr[0]<=4;
      send_packet(round*16+8);send_packet(round*16+9);
      wait_completed(10);settle();
      chk(sta_wptr[0]==10 && sta_level[0]==6,"visible progress after host update");
      if(completed==10)begin
        chk(seen_data[8][95:0]===packet(round*16+8),"first retained record");
        chk(seen_data[9][95:0]===packet(round*16+9),"second retained record");
        chk(seen_addr[8]==48'h20000000 && seen_addr[9]==48'h20000010,"ring wrap addresses");
      end
    end
    $display("P2 complete (%0d checks, %0d errors)",checks,errs);
    if(errs || checks==0)$fatal(1,"RECV POINTERS TB FAIL (%0d/%0d)",errs,checks);
    $display("RECV POINTERS TB PASS (%0d checks)",checks);
    $finish;
  end
  initial begin #10ms;$fatal(1,"RECV POINTERS TB TIMEOUT");end
endmodule
