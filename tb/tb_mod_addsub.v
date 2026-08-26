// ---------------------------------------------------------------------------
// tb_mod_addsub.v -- self-checking testbench for mod_addsub.v
//
// Reads vectors/tv_modaddsub.txt  (a, b, expected_sum, expected_diff)
//
// Run from the PROJECT ROOT:
//   iverilog -g2012 -o build/tb_mod_addsub.vvp tb/tb_mod_addsub.v rtl/mod_addsub.v
//   vvp build/tb_mod_addsub.vvp
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_mod_addsub;

    localparam integer COEFF_W = 12;
    localparam         VECFILE = "vectors/tv_modaddsub.txt";

    reg  [COEFF_W-1:0] a = 0, b = 0;
    wire [COEFF_W-1:0] sum, diff;

    integer fd, code, i;
    integer n_pass = 0, n_fail_sum = 0, n_fail_diff = 0;
    reg [1023:0] hdr;
    reg [COEFF_W-1:0] va, vb, vsum, vdiff;

    mod_addsub #(
        .COEFF_W (COEFF_W),
        .Q       (3329)
    ) dut (
        .a    (a),
        .b    (b),
        .sum  (sum),
        .diff (diff)
    );

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_mod_addsub.vcd");
            $dumpvars(0, tb_mod_addsub);
        end

        fd = $fopen(VECFILE, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open %s", VECFILE);
            $display("       Run from the PROJECT ROOT, not from tb/.");
            $finish;
        end

        code = $fgets(hdr, fd);          // discard the single '#' header line

        i = 0;
        while ($fscanf(fd, "%h %h %h %h\n", va, vb, vsum, vdiff) == 4) begin
            a = va;
            b = vb;
            #1;                          // settle combinational logic

            if (sum !== vsum) begin
                n_fail_sum = n_fail_sum + 1;
                if (n_fail_sum <= 5)
                    $display("FAIL sum  a=%4d b=%4d  got=%4d  expected=%4d",
                             va, vb, sum, vsum);
            end

            if (diff !== vdiff) begin
                n_fail_diff = n_fail_diff + 1;
                if (n_fail_diff <= 5)
                    $display("FAIL diff a=%4d b=%4d  got=%4d  expected=%4d",
                             va, vb, diff, vdiff);
            end

            if (sum === vsum && diff === vdiff)
                n_pass = n_pass + 1;

            i = i + 1;
        end
        $fclose(fd);

        $display("");
        $display("=====================================================");
        $display(" mod_addsub : %0d vectors,  %0d pass", i, n_pass);
        $display("              sum  failures: %0d", n_fail_sum);
        $display("              diff failures: %0d", n_fail_diff);
        if (n_fail_sum == 0 && n_fail_diff == 0 && n_pass > 0)
            $display(" RESULT: PASS");
        else
            $display(" RESULT: FAIL");
        $display("=====================================================");
        $finish;
    end

endmodule
