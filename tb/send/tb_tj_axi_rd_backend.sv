// File        : tb_tj_axi_rd_backend.sv
// Module      : tb_tj_axi_rd_backend
// Description : Check AXI read mapping, response errors and width restrictions.
`timescale 1ns/1ps
`ifndef TEST_DW
`define TEST_DW 128
`endif
module tb_tj_axi_rd_backend;
  logic clk = 0, rst_n = 0;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
  logic [39:0] req_addr = 0;
  logic [7:0] req_len = 1;
  logic [127:0] rsp_data;
  logic rsp_last, rsp_err;
  logic arvalid, arready = 0;
  logic [3:0] arid, rid = 4'h3;
  logic [47:0] araddr;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst;
  logic rvalid = 0, rready, rlast = 0;
  logic [`TEST_DW-1:0] rdata = 0;
  logic [1:0] rresp = 0;
  tj_axi_rd_backend #(.AXI_DW(`TEST_DW), .RD_ID(4'h3)) dut (.*);
  always #5 clk = ~clk;
  int checks = 0, errs = 0;
  task automatic chk(input bit ok, input string msg);
    checks++; if (!ok) begin errs++; $display("FAIL: %s", msg); end
  endtask
  initial begin
    #20; rst_n = 1;
    req_valid = 1; req_addr = 40'hAB12345000; req_len = 64;
    #1;
    chk(arvalid && !req_ready && araddr == 48'h00AB12345000,
        "pending request and zero-extended address");
    chk(arid == 3 && arlen == 63 && arsize == 4 && arburst == 1, "AXI metadata");
    repeat (4) begin
      #10; chk(arvalid && araddr == 48'h00AB12345000 && arlen == 63, "AR held until acceptance");
    end
    arready = 1; #1; chk(req_ready && arvalid, "request handshake");
    req_valid = 0; #1; chk(!arvalid, "no extra request");
    for (int response=0; response<4; response++) begin
      rvalid = 1; rdata = {32'h01234567,32'h89ABCDEF,32'h13579BDF,32'h2468ACE0};
      rresp = 2'(response); rlast = response[0]; rsp_ready = 0;
      #1;
      chk(rsp_valid && !rready, "R backpressure");
      chk(rsp_data === 128'h0123456789ABCDEF13579BDF2468ACE0 && rsp_last == response[0],
          "read data and last preserved");
      chk(rsp_err == (response>=2), "OKAY/EXOKAY versus SLVERR/DECERR");
      #20; rsp_ready = 1; #1; chk(rready && rsp_valid, "read response handshake");
      rvalid = 0; #1; chk(!rsp_valid, "no extra response");
    end
    if (errs == 0 && checks > 0) $display("AXI READ BACKEND TB PASS (%0d checks)", checks);
    else $display("AXI READ BACKEND TB FAIL (%0d/%0d checks)", errs, checks);
    $finish;
  end
endmodule
