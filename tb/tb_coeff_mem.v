// ---------------------------------------------------------------------------
// tb_coeff_mem.v -- self-checking testbench for coeff_mem.v
//
// Two phases:
//   1. Write all 256 locations with data == address, using (2r, 2r+1) pairs
//      (always opposite parity, so both ports are exercised every cycle).
//   2. Replay EVERY butterfly access of the real 7-layer NTT schedule from
//      vectors/addr_schedule.txt and check both ports return the right data.
//
// Phase 2 is the real test: 896 genuine (j, j+len) pairs across all layers.
// If the crossbar or the delayed bank select is wrong, this finds it.
// It also re-asserts that the parity scheme has zero conflicts.
//
// addr_schedule.txt: 13 DECIMAL columns, ONE '#' header line:
//   layer len k j jl bLSBj bLSBjl confLSB bPARj bPARjl confPAR rowj rowjl
//
// Run from the PROJECT ROOT:
//   iverilog -g2012 -o build/tb_coeff_mem.vvp tb/tb_coeff_mem.v rtl/coeff_mem.v
//   vvp build/tb_coeff_mem.vvp
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_coeff_mem;

    localparam integer COEFF_W = 12;
    localparam integer ADDR_W  = 8;

    reg                clk = 1'b0;
    reg                rst_n = 1'b0;
    reg  [ADDR_W-1:0]  addr_a = 0, addr_b = 0;
    reg                we_a = 0, we_b = 0;
    reg  [COEFF_W-1:0] wdata_a = 0, wdata_b = 0;
    wire [COEFF_W-1:0] rdata_a, rdata_b;

    integer r, fd, code, n_pairs;
    integer n_fail_data = 0, n_fail_conf = 0, n_pass = 0;
    reg [1023:0] hdr;
    integer layer, len, k, j, jl;
    integer bl_j, bl_jl, cl, bp_j, bp_jl, cp, rj, rjl;

    always #5 clk = ~clk;

    coeff_mem #(
        .COEFF_W (COEFF_W),
        .ADDR_W  (ADDR_W),
        .ROW_W   (7),
        .DEPTH   (128)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .ren (1'b1), .raddr_a (addr_a), .raddr_b (addr_b),
        .rdata_a (rdata_a), .rdata_b (rdata_b),
        .waddr_a (addr_a), .waddr_b (addr_b),
        .we_a (we_a), .we_b (we_b), .wdata_a (wdata_a), .wdata_b (wdata_b)
    );

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_coeff_mem.vcd");
            $dumpvars(0, tb_coeff_mem);
        end

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---- Phase 1: fill memory, data == address -------------------------
        // (2r, 2r+1) always have opposite parity, so this is a legal pair.
        for (r = 0; r < 128; r = r + 1) begin
            @(negedge clk);
            addr_a  = 2*r;      wdata_a = 2*r;      we_a = 1'b1;
            addr_b  = 2*r + 1;  wdata_b = 2*r + 1;  we_b = 1'b1;
        end
        @(negedge clk);
        we_a = 1'b0; we_b = 1'b0;
        repeat (2) @(negedge clk);

        $display("");
        $display("=====================================================");
        $display(" phase 1: wrote 256 locations (data == address)");

        // ---- Phase 2: replay the real NTT address schedule -----------------
        fd = $fopen("vectors/addr_schedule.txt", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open vectors/addr_schedule.txt");
            $display("       Run from the PROJECT ROOT, not from tb/.");
            $finish;
        end
        code = $fgets(hdr, fd);          // one header line

        n_pairs = 0;
        while ($fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                       layer, len, k, j, jl,
                       bl_j, bl_jl, cl, bp_j, bp_jl, cp, rj, rjl) == 13) begin

            if (cp != 0) begin
                n_fail_conf = n_fail_conf + 1;
                if (n_fail_conf <= 3)
                    $display(" FAIL[conflict] layer=%0d j=%0d jl=%0d : parity banking conflicted",
                             layer, j, jl);
            end

            @(negedge clk);
            addr_a = j;  addr_b = jl;  we_a = 1'b0;  we_b = 1'b0;

            @(negedge clk);              // 1-cycle read latency

            if (rdata_a !== j[COEFF_W-1:0] || rdata_b !== jl[COEFF_W-1:0]) begin
                n_fail_data = n_fail_data + 1;
                if (n_fail_data <= 10)
                    $display(" FAIL layer=%0d len=%3d  addr_a=%3d addr_b=%3d | got %4d / %4d | expected %4d / %4d",
                             layer, len, j, jl, rdata_a, rdata_b, j, jl);
            end else begin
                n_pass = n_pass + 1;
            end
            n_pairs = n_pairs + 1;
        end
        $fclose(fd);

        $display(" phase 2: replayed %0d butterfly address pairs", n_pairs);
        $display("          data mismatches     : %0d", n_fail_data);
        $display("          banking conflicts   : %0d", n_fail_conf);
        $display("-----------------------------------------------------");
        $display(" coeff_mem : %0d pass / %0d", n_pass, n_pairs);
        if (n_fail_data == 0 && n_fail_conf == 0 && n_pairs == 896)
            $display(" RESULT: PASS");
        else if (n_pairs != 896)
            $display(" RESULT: FAIL -- expected 896 pairs (7 layers x 128), got %0d", n_pairs);
        else
            $display(" RESULT: FAIL");
        $display("=====================================================");
        $finish;
    end

    initial begin
        #10_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
