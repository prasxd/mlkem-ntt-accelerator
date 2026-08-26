`timescale 1ns/1ps
module tb_base_mult;
  localparam CW=12;
  reg clk=0, rst_n=0, start=0;
  reg [CW-1:0] g=0,a0=0,a1=0,b0=0,b1=0;
  wire [CW-1:0] c0,c1; wire busy, done;
  integer fd, code, got, n=0, bad=0, cyc, tot_cyc=0;
  reg [1023:0] hdr;
  reg [CW-1:0] vg,va0,va1,vb0,vb1,vc0,vc1;
  always #5 clk=~clk;
  base_mult dut(.clk(clk),.rst_n(rst_n),.start(start),.g_mont(g),
    .a0(a0),.a1(a1),.b0(b0),.b1(b1),.c0(c0),.c1(c1),.busy(busy),.done(done));
  initial begin
    repeat(4) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);
    fd=$fopen("vectors/tv_basemul.txt","r");
    if (fd==0) begin $display("ERROR: run from PROJECT ROOT"); $finish; end
    code=$fgets(hdr,fd); code=$fgets(hdr,fd);
    while ($fscanf(fd,"%h %h %h %h %h %h %h\n",vg,va0,va1,vb0,vb1,vc0,vc1)==7) begin
      @(negedge clk); g=vg; a0=va0; a1=va1; b0=vb0; b1=vb1; start=1'b1;
      @(negedge clk); start=1'b0; cyc=1;
      while (!done && cyc<200) begin @(negedge clk); cyc=cyc+1; end
      tot_cyc = tot_cyc + cyc;
      if (c0!==vc0 || c1!==vc1) begin
        bad=bad+1;
        if (bad<=6) $display(" FAIL #%0d g=%0d a=(%0d,%0d) b=(%0d,%0d) | got (%0d,%0d) exp (%0d,%0d)",
                             n,vg,va0,va1,vb0,vb1,c0,c1,vc0,vc1);
      end
      n=n+1;
    end
    $fclose(fd);
    $display("");
    $display("=====================================================");
    $display(" base_mult : %0d pairs, %0d errors, %0d cycles/pair avg", n, bad, tot_cyc/n);
    if (bad==0 && n>0) $display(" RESULT: PASS"); else $display(" RESULT: FAIL");
    $display("=====================================================");
    $finish;
  end
  initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
