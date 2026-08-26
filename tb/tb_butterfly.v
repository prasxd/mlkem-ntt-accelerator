// ---------------------------------------------------------------------------
// tb_butterfly.v -- self-checking testbench for butterfly.v
//
// Runs BOTH modes:
//   vectors/tv_butterfly_ct.txt  (mode 0, Cooley-Tukey / forward)
//   vectors/tv_butterfly_gs.txt  (mode 1, Gentleman-Sande / inverse)
//
// Vector format (6 hex columns, TWO '#' header lines):
//   z_mont  z  a  b  a_out  b_out
// The DUT is fed z_mont (Montgomery domain); plain z is there for debug only.
//
// Run from the PROJECT ROOT:
//   iverilog -g2012 -o build/tb_butterfly.vvp tb/tb_butterfly.v \
//            rtl/butterfly.v rtl/mont_mul.v rtl/mod_addsub.v
//   vvp build/tb_butterfly.vvp
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_butterfly;

    localparam integer COEFF_W = 12;
    localparam integer LATENCY = 4;      // mont_mul 3 + output register 1

    reg                clk = 1'b0;
    reg                rst_n = 1'b0;
    reg                valid_in = 1'b0;
    reg                mode = 1'b0;
    reg  [COEFF_W-1:0] z_mont = 0, a = 0, b = 0;
    wire [COEFF_W-1:0] a_out, b_out;
    wire               valid_out;

    integer n_pass, n_fail, n_total;
    integer grand_pass = 0, grand_fail = 0;

    always #5 clk = ~clk;                // 100 MHz

    butterfly #(
        .COEFF_W (COEFF_W),
        .Q       (3329),
        .QINV    (3327),
        .MUL_LAT (3)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .mode      (mode),
        .z_mont    (z_mont),
        .a         (a),
        .b         (b),
        .a_out     (a_out),
        .b_out     (b_out),
        .valid_out (valid_out)
    );

    task run_file(input [8*64-1:0] path, input test_mode, input [8*8-1:0] label);
        integer fd, code, k;
        reg [1023:0] hdr;
        reg [COEFF_W-1:0] vzm, vz, va, vb, vea, veb;
        begin
            n_pass = 0; n_fail = 0; n_total = 0;

            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("ERROR: cannot open %0s", path);
                $display("       Run from the PROJECT ROOT, not from tb/.");
                $finish;
            end

            code = $fgets(hdr, fd);      // header line 1
            code = $fgets(hdr, fd);      // header line 2  <-- TWO of them now

            while ($fscanf(fd, "%h %h %h %h %h %h\n",
                           vzm, vz, va, vb, vea, veb) == 6) begin
                @(negedge clk);
                mode = test_mode; z_mont = vzm; a = va; b = vb;
                valid_in = 1'b1;
                @(negedge clk);
                valid_in = 1'b0;

                repeat (LATENCY - 1) @(negedge clk);

                if (!valid_out) begin
                    n_fail = n_fail + 1;
                    if (n_fail <= 5)
                        $display("FAIL[%0s no valid] z=%0d a=%0d b=%0d : valid_out low at LATENCY=%0d",
                                 label, vz, va, vb, LATENCY);
                end else if (a_out !== vea || b_out !== veb) begin
                    n_fail = n_fail + 1;
                    if (n_fail <= 5)
                        $display("FAIL[%0s] z=%4d a=%4d b=%4d | got a_out=%4d b_out=%4d | exp a_out=%4d b_out=%4d",
                                 label, vz, va, vb, a_out, b_out, vea, veb);
                end else begin
                    n_pass = n_pass + 1;
                end
                n_total = n_total + 1;
            end
            $fclose(fd);

            $display(" %0s : %0d vectors,  %0d pass,  %0d fail",
                     label, n_total, n_pass, n_fail);
            grand_pass = grand_pass + n_pass;
            grand_fail = grand_fail + n_fail;
        end
    endtask

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_butterfly.vcd");
            $dumpvars(0, tb_butterfly);
        end

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("");
        $display("=====================================================");
        run_file("vectors/tv_butterfly_ct.txt", 1'b0, "CT");
        repeat (LATENCY + 2) @(negedge clk);      // flush between modes
        run_file("vectors/tv_butterfly_gs.txt", 1'b1, "GS");
        $display("-----------------------------------------------------");
        $display(" TOTAL: %0d pass, %0d fail", grand_pass, grand_fail);
        if (grand_fail == 0 && grand_pass > 0)
            $display(" RESULT: PASS");
        else
            $display(" RESULT: FAIL");
        $display("=====================================================");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT -- check valid_out and LATENCY.");
        $finish;
    end

endmodule
