`timescale 1ns/1ps
module tb_stall2;
  reg clk=0, rst_n=0, start=0, mode=0, en=1;
  wire valid, busy, done, last_in_layer;
  wire [7:0] aa, ab; wire [6:0] kk; wire [2:0] ll;
  integer cnt=0, fd, code, got, bad=0;
  integer e_layer,e_len,e_k,e_j,e_jl,d1,d2,d3,d4,d5,d6,d7,d8;
  reg [1023:0] hdr;
  always #5 clk=~clk;
  addr_gen dut(.clk(clk),.rst_n(rst_n),.start(start),.mode(mode),.en(en),
    .valid(valid),.addr_a(aa),.addr_b(ab),.k(kk),.layer(ll),
    .last_in_layer(last_in_layer),.busy(busy),.done(done));
  // chaotic enable: random stalls throughout
  always @(negedge clk) if (busy) en = ($random % 10) > 2;
  always @(negedge clk) begin
    if (valid) begin
      got = $fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                    e_layer,e_len,e_k,e_j,e_jl,d1,d2,d3,d4,d5,d6,d7,d8);
      if (got!=13) begin bad=bad+1; end
      else if (aa!==e_j[7:0] || ab!==e_jl[7:0] || kk!==e_k[6:0] || ll!==e_layer[2:0]) begin
        bad=bad+1;
        if (bad<=5) $display("FAIL bf#%0d got l=%0d k=%0d j=%0d jl=%0d | exp l=%0d k=%0d j=%0d jl=%0d",
                             cnt,ll,kk,aa,ab,e_layer,e_k,e_j,e_jl);
      end
      cnt=cnt+1;
    end
  end
  initial begin
    fd=$fopen("vectors/addr_schedule.txt","r"); code=$fgets(hdr,fd);
    repeat(4) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);
    start=1; @(negedge clk); start=0;
    wait(done); repeat(3) @(negedge clk);
    $display("randomly-stalled run: %0d butterflies, %0d mismatches", cnt, bad);
    if (cnt==896 && bad==0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
  initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
