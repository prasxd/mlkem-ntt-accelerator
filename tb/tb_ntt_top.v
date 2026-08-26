`timescale 1ns/1ps
// Drives ntt_top entirely through its AXI interfaces: AXI4-Lite register
// writes to configure and start, AXI4-Stream in for coefficients, AXI4-Stream
// out for results, AXI4-Lite reads for STATUS and CYCLES.
module tb_ntt_top;
  reg clk=0, rst_n=0;
  reg [3:0] awaddr=0; reg awvalid=0; wire awready;
  reg [31:0] wdata=0;  reg [3:0] wstrb=4'hF; reg wvalid=0; wire wready;
  wire [1:0] bresp; wire bvalid; reg bready=1;
  reg [3:0] araddr=0; reg arvalid=0; wire arready;
  wire [31:0] rdata; wire [1:0] rresp; wire rvalid; reg rready=1;
  reg [15:0] tdata=0; reg tvalid=0; wire tready;
  wire [15:0] mdata; wire mvalid, mlast; reg mready=1;

  reg [11:0] inv[0:255], exp[0:255], got[0:255];
  integer i,t,gi,errs,cyc,bpc,total_err=0,lastbeat;
  reg bp_en=0;
  reg [31:0] rd;
  reg [8*40-1:0] f1,f2; reg [8*10-1:0] lb;

  always #5 clk=~clk;

  ntt_top dut(.clk(clk),.rst_n(rst_n),
    .s_axil_awaddr(awaddr),.s_axil_awvalid(awvalid),.s_axil_awready(awready),
    .s_axil_wdata(wdata),.s_axil_wstrb(wstrb),.s_axil_wvalid(wvalid),.s_axil_wready(wready),
    .s_axil_bresp(bresp),.s_axil_bvalid(bvalid),.s_axil_bready(bready),
    .s_axil_araddr(araddr),.s_axil_arvalid(arvalid),.s_axil_arready(arready),
    .s_axil_rdata(rdata),.s_axil_rresp(rresp),.s_axil_rvalid(rvalid),.s_axil_rready(rready),
    .s_axis_tdata(tdata),.s_axis_tvalid(tvalid),.s_axis_tready(tready),
    .m_axis_tdata(mdata),.m_axis_tvalid(mvalid),.m_axis_tready(mready),.m_axis_tlast(mlast));

  task axil_write(input [3:0] a, input [31:0] d);
    begin
      @(negedge clk); awaddr=a; awvalid=1; wdata=d; wvalid=1;
      while (!(awready && wready)) @(negedge clk);
      @(negedge clk); awvalid=0; wvalid=0;
      while (!bvalid) @(negedge clk);
      @(negedge clk);
    end
  endtask

  task axil_read(input [3:0] a, output [31:0] d);
    begin
      @(negedge clk); araddr=a; arvalid=1;
      while (!arready) @(negedge clk);
      @(negedge clk); arvalid=0;
      while (!rvalid) @(negedge clk);
      d = rdata;
      @(negedge clk);
    end
  endtask

  task run_case(input [8*40-1:0] fin, input [8*40-1:0] fexp,
                input tmode, input [8*10-1:0] label);
    begin
      $readmemh(fin,inv); $readmemh(fexp,exp);
      gi=0; errs=0; cyc=0; bpc=0; mready=1; lastbeat=0;
      for (i=0;i<256;i=i+1) got[i]=12'hFFF;

      axil_write(4'h4, {31'd0, tmode});     // MODE
      axil_write(4'h0, 32'h1);              // CTRL.start

      // stream 256 coefficients in, honouring tready
      i=0;
      while (i<256) begin
        @(negedge clk); tdata={4'd0,inv[i]}; tvalid=1;
        if (tready) i=i+1;
      end
      @(negedge clk); tvalid=0;

      // collect 256 beats out, honouring tvalid/tready
      while (gi<256 && cyc<30000) begin
        @(negedge clk);
        if (mvalid && mready) begin
          got[gi]=mdata[11:0]; gi=gi+1;
          if (mlast) lastbeat=gi;
        end
        mready = (bp_en) ? ((bpc%3)!=0) : 1'b1;
        bpc=bpc+1; cyc=cyc+1;
      end
      mready=1;
      repeat(20) @(negedge clk);

      for (i=0;i<256;i=i+1)
        if (got[i]!==exp[i]) begin
          errs=errs+1;
          if (errs<=3) $display("  [%0s] coeff %3d got %4d exp %4d",label,i,got[i],exp[i]);
        end

      axil_read(4'h8, rd);
      if (rd[0] !== 1'b0) $display("  [%0s] STATUS.busy still set", label);
      if (rd[1] !== 1'b1) $display("  [%0s] STATUS.done not set", label);
      axil_write(4'h8, 32'h2);              // W1C the done bit
      axil_read(4'h8, rd);
      if (rd[1] !== 1'b0) $display("  [%0s] STATUS.done did not clear", label);
      axil_read(4'hC, rd);                  // CYCLES

      $display(" %-9s : %0d beats, %0d errors, CYCLES=%0d", label, gi, errs, rd);
      total_err = total_err + errs + (gi!=256) + (lastbeat!=256);
    end
  endtask

  initial begin
    repeat(4) @(negedge clk); rst_n=1; repeat(4) @(negedge clk);
    axil_read(4'h4, rd);
    $display("");
    $display("=====================================================");
    for (t=0;t<4;t=t+1) begin
      $sformat(f1,"vectors/ntt_%0d_in.mem",t); $sformat(f2,"vectors/ntt_%0d_out.mem",t);
      $sformat(lb,"NTT%0d",t);  run_case(f1,f2,1'b0,lb);
    end
    for (t=0;t<4;t=t+1) begin
      $sformat(f1,"vectors/ntt_%0d_out.mem",t); $sformat(f2,"vectors/intt_%0d_out.mem",t);
      $sformat(lb,"INTT%0d",t); run_case(f1,f2,1'b1,lb);
    end
    $display(" --- with AXI-Stream backpressure ---");
    bp_en=1;
    for (t=0;t<2;t=t+1) begin
      $sformat(f1,"vectors/ntt_%0d_in.mem",t); $sformat(f2,"vectors/ntt_%0d_out.mem",t);
      $sformat(lb,"BP-NTT%0d",t);  run_case(f1,f2,1'b0,lb);
    end
    for (t=0;t<2;t=t+1) begin
      $sformat(f1,"vectors/ntt_%0d_out.mem",t); $sformat(f2,"vectors/intt_%0d_out.mem",t);
      $sformat(lb,"BP-INTT%0d",t); run_case(f1,f2,1'b1,lb);
    end
    $display("-----------------------------------------------------");
    if (total_err==0) $display(" RESULT: PASS"); else $display(" RESULT: FAIL (%0d)",total_err);
    $display("=====================================================");
    $finish;
  end
  initial begin #300_000_000; $display("TIMEOUT"); $finish; end
endmodule
