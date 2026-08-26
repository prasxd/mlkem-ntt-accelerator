`timescale 1ns/1ps
// ntt_core end-to-end: all 8 golden polynomials, NTT and INTT,
// each run twice -- once with tready held high, once with tready stalling
// 1 cycle in 3 during STORE to exercise AXI-Stream backpressure.
module tb_ntt_core;
  localparam CW=12;
  reg clk=0, rst_n=0, start=0, mode=0, s_valid=0, m_ready=1;
  reg [CW-1:0] s_data=0;
  wire m_valid, m_last, busy, done;
  wire [CW-1:0] m_data;

  reg [CW-1:0] inv[0:255], exp[0:255], got[0:255];
  integer i, t, gi, errs, cyc, bpc, total_err=0, last_seen;
  reg bp_en = 1'b0; reg saw_done;
  reg [8*40-1:0] f1, f2; reg [8*10-1:0] lb;

  always #5 clk=~clk;

  wire core_loading;
  ntt_core dut(.clk(clk),.rst_n(rst_n),.start(start),.mode(mode),.loading(core_loading),
    .s_valid(s_valid),.s_data(s_data),.m_valid(m_valid),.m_data(m_data),
    .m_last(m_last),.m_ready(m_ready),.busy(busy),.done(done));

  // Capture lives INSIDE the task -- no free-running always block, so nothing
  // leaks between cases.
  task run_case(input [8*40-1:0] fin, input [8*40-1:0] fexp,
                input tmode, input [8*10-1:0] label);
    begin
      $readmemh(fin, inv); $readmemh(fexp, exp);
      gi=0; errs=0; cyc=0; bpc=0; m_ready=1'b1; last_seen=0;
      for (i=0;i<256;i=i+1) got[i]=12'hFFF;   // poison, so a missing beat shows

      @(negedge clk); mode=tmode; start=1'b1;
      @(negedge clk); start=1'b0;
      for (i=0;i<256;i=i+1) begin @(negedge clk); s_valid=1'b1; s_data=inv[i]; end
      @(negedge clk); s_valid=1'b0;

      while (gi < 256 && cyc < 20000) begin
        @(negedge clk);
        if (m_valid && m_ready) begin
          got[gi]=m_data; gi=gi+1;
          if (m_last) last_seen = gi;
        end
        m_ready = (bp_en && dut.state==3'd4) ? ((bpc % 3) != 0) : 1'b1;
        bpc = bpc + 1;
        cyc = cyc + 1;
      end
      // Keep tready HIGH until the core actually leaves STORE. After the
      // 256th beat it still needs one more accepted cycle to reach S_DONE;
      // freezing tready low here would leave it busy and the next start
      // would be ignored. Also latch `done` -- it is a one-cycle pulse.
      m_ready = 1'b1;
      saw_done = 1'b0;
      while (!saw_done && cyc < 20000) begin
        @(negedge clk);
        if (done) saw_done = 1'b1;
        cyc = cyc + 1;
      end
      if (!saw_done) $display("  [%0s] done never asserted", label);

      for (i=0;i<256;i=i+1)
        if (got[i] !== exp[i]) begin
          errs=errs+1;
          if (errs<=4) $display("  [%0s] coeff %3d: got %4d expected %4d",
                                label, i, got[i], exp[i]);
        end
      if (last_seen != 256)
        $display("  [%0s] tlast on beat %0d, expected 256", label, last_seen);
      $display(" %-7s : %0d beats, %0d errors, %0d cycles", label, gi, errs, cyc);
      total_err = total_err + errs + (gi!=256) + (last_seen!=256) + (!saw_done);
      repeat(8) @(negedge clk);
    end
  endtask

  initial begin
    repeat(4) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);
    $display("");
    $display("=====================================================");
    for (t=0;t<8;t=t+1) begin
      $sformat(f1,"vectors/ntt_%0d_in.mem",t);
      $sformat(f2,"vectors/ntt_%0d_out.mem",t);
      $sformat(lb,"NTT%0d",t);  run_case(f1,f2,1'b0,lb);
    end
    for (t=0;t<8;t=t+1) begin
      $sformat(f1,"vectors/ntt_%0d_out.mem",t);
      $sformat(f2,"vectors/intt_%0d_out.mem",t);
      $sformat(lb,"INTT%0d",t); run_case(f1,f2,1'b1,lb);
    end
    $display(" --- repeating with AXI-Stream backpressure (stall 1 in 3) ---");
    repeat(4) @(negedge clk); bp_en = 1'b1; repeat(4) @(negedge clk);
    for (t=0;t<8;t=t+1) begin
      $sformat(f1,"vectors/ntt_%0d_in.mem",t);
      $sformat(f2,"vectors/ntt_%0d_out.mem",t);
      $sformat(lb,"BP-NTT%0d",t);  run_case(f1,f2,1'b0,lb);
    end
    for (t=0;t<8;t=t+1) begin
      $sformat(f1,"vectors/ntt_%0d_out.mem",t);
      $sformat(f2,"vectors/intt_%0d_out.mem",t);
      $sformat(lb,"BP-INTT%0d",t); run_case(f1,f2,1'b1,lb);
    end
    $display("-----------------------------------------------------");
    if (total_err==0) $display(" RESULT: PASS");
    else              $display(" RESULT: FAIL (%0d)", total_err);
    $display("=====================================================");
    $finish;
  end
  initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
