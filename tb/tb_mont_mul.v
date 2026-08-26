// ---------------------------------------------------------------------------
// tb_mont_mul.v -- self-checking testbench for mont_mul.v
//
// Reads vectors/tv_montmul.txt (a, b, expected) and reports pass/fail.
//
// Run from the project root:
//   iverilog -g2012 -o build/tb_mont_mul.vvp tb/tb_mont_mul.v rtl/mont_mul.v
//   vvp build/tb_mont_mul.vvp
//
// Waveform:  vvp build/tb_mont_mul.vvp +dump   then  gtkwave tb_mont_mul.vcd
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_mont_mul;

    localparam integer COEFF_W = 12;
    localparam integer LATENCY = 3;      // must match mont_mul's stage count
    localparam         VECFILE = "vectors/tv_montmul.txt";

    reg                clk = 1'b0;
    reg                rst_n = 1'b0;
    reg                valid_in = 1'b0;
    reg  [COEFF_W-1:0] a = 0, b = 0;
    wire [COEFF_W-1:0] out;
    wire               valid_out;

    integer fd, code, i;
    integer n_pass = 0, n_fail = 0;
    reg [1023:0] hdr;
    reg [COEFF_W-1:0] va, vb, vexp;

    always #5 clk = ~clk;                // 100 MHz

    mont_mul #(
        .COEFF_W (COEFF_W),
        .Q       (3329),
        .QINV    (3327)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .a         (a),
        .b         (b),
        .out       (out),
        .valid_out (valid_out)
    );

    // ---- one vector at a time: simple, unambiguous, fast enough -----------
    task apply_and_check(input [COEFF_W-1:0] ta,
                         input [COEFF_W-1:0] tb_,
                         input [COEFF_W-1:0] texp);
        begin
            @(negedge clk);
            a = ta; b = tb_; valid_in = 1'b1;
            @(negedge clk);
            valid_in = 1'b0;

            repeat (LATENCY - 1) @(negedge clk);

            if (!valid_out) begin
                n_fail = n_fail + 1;
                if (n_fail <= 10)
                    $display("FAIL[no valid] a=%0d b=%0d : valid_out never asserted at LATENCY=%0d",
                             ta, tb_, LATENCY);
            end else if (out !== texp) begin
                n_fail = n_fail + 1;
                if (n_fail <= 10)
                    $display("FAIL a=%4d b=%4d  got=%4d  expected=%4d",
                             ta, tb_, out, texp);
            end else begin
                n_pass = n_pass + 1;
            end
        end
    endtask

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_mont_mul.vcd");
            $dumpvars(0, tb_mont_mul);
        end

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        fd = $fopen(VECFILE, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open %s", VECFILE);
            $display("       Run the testbench from the PROJECT ROOT, not tb/.");
            $finish;
        end

        code = $fgets(hdr, fd);          // discard the single '#' header line

        i = 0;
        while ($fscanf(fd, "%h %h %h\n", va, vb, vexp) == 3) begin
            apply_and_check(va, vb, vexp);
            i = i + 1;
        end
        $fclose(fd);

        $display("");
        $display("=====================================================");
        $display(" mont_mul : %0d vectors,  %0d pass,  %0d fail",
                 i, n_pass, n_fail);
        if (n_fail == 0 && n_pass > 0)
            $display(" RESULT: PASS");
        else
            $display(" RESULT: FAIL");
        $display("=====================================================");
        $finish;
    end

    // safety net so a broken DUT cannot hang the run
    initial begin
        #20_000_000;
        $display("TIMEOUT -- DUT never completed. Check valid_out and LATENCY.");
        $finish;
    end

endmodule
