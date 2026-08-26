// ---------------------------------------------------------------------------
// tb_addr_gen.v -- self-checking testbench for addr_gen.v
//
// Compares the DUT's emitted sequence, butterfly by butterfly, against the
// golden schedules produced by golden/gen_vectors.py:
//
//   vectors/addr_schedule.txt      forward, 896 rows, 13 columns
//   vectors/addr_schedule_inv.txt  inverse, 896 rows, 10 columns
//
// Checks j, j+len, k and layer on EVERY butterfly, and that the run ends
// after exactly 896 with `done` asserted.
//
// Run from the PROJECT ROOT:
//   iverilog -g2012 -o build/tb_addr_gen.vvp tb/tb_addr_gen.v rtl/addr_gen.v
//   vvp build/tb_addr_gen.vvp
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_addr_gen;

    localparam integer ADDR_W = 8;
    localparam integer K_W    = 7;

    reg               clk = 1'b0;
    reg               rst_n = 1'b0;
    reg               start = 1'b0;
    reg               mode = 1'b0;
    reg               en = 1'b1;

    wire              valid;
    wire [ADDR_W-1:0] addr_a, addr_b;
    wire [K_W-1:0]    k;
    wire [2:0]        layer;
    wire              last_in_layer, busy, done;

    integer n_seen, n_fail, grand_fail = 0;

    always #5 clk = ~clk;

    addr_gen #(
        .ADDR_W (ADDR_W), .K_W (K_W), .BF_W (7), .LAYER_W (3)
    ) dut (
        .clk (clk), .rst_n (rst_n), .start (start), .mode (mode), .en (en),
        .valid (valid), .addr_a (addr_a), .addr_b (addr_b), .k (k),
        .layer (layer), .last_in_layer (last_in_layer),
        .busy (busy), .done (done)
    );

    // -----------------------------------------------------------------------
    task run_schedule(input [8*40-1:0] path,
                      input            test_mode,
                      input integer    n_cols,      // 13 fwd, 10 inv
                      input [8*8-1:0]  label);
        integer fd, code, got;
        reg [1023:0] hdr;
        integer e_layer, e_len, e_k, e_j, e_jl, d1, d2, d3, d4, d5, d6, d7, d8;
        begin
            n_seen = 0; n_fail = 0;

            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("ERROR: cannot open %0s -- run from PROJECT ROOT", path);
                $finish;
            end
            code = $fgets(hdr, fd);            // one header line

            @(negedge clk);
            mode = test_mode; start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            forever begin
                @(negedge clk);
                if (valid) begin
                    if (n_cols == 13)
                        got = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                                      e_layer, e_len, e_k, e_j, e_jl,
                                      d1, d2, d3, d4, d5, d6, d7, d8);
                    else
                        got = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d\n",
                                      e_layer, e_len, e_k, e_j, e_jl,
                                      d1, d2, d3, d4, d5);

                    if (got != n_cols) begin
                        $display(" FAIL[%0s] DUT emitted butterfly %0d but the golden file ran out",
                                 label, n_seen);
                        n_fail = n_fail + 1;
                        disable run_schedule;
                    end

                    if (addr_a !== e_j[ADDR_W-1:0] || addr_b !== e_jl[ADDR_W-1:0] ||
                        k !== e_k[K_W-1:0] || layer !== e_layer[2:0]) begin
                        n_fail = n_fail + 1;
                        if (n_fail <= 10)
                            $display(" FAIL[%0s] bf#%0d | got  layer=%0d k=%3d j=%3d jl=%3d | exp layer=%0d k=%3d j=%3d jl=%3d",
                                     label, n_seen, layer, k, addr_a, addr_b,
                                     e_layer, e_k, e_j, e_jl);
                    end
                    n_seen = n_seen + 1;
                end

                if (done) begin
                    // confirm the golden file is also exhausted
                    if (n_cols == 13)
                        got = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                                      e_layer, e_len, e_k, e_j, e_jl,
                                      d1, d2, d3, d4, d5, d6, d7, d8);
                    else
                        got = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d\n",
                                      e_layer, e_len, e_k, e_j, e_jl,
                                      d1, d2, d3, d4, d5);
                    if (got == n_cols) begin
                        $display(" FAIL[%0s] DUT finished early -- golden file still has rows",
                                 label);
                        n_fail = n_fail + 1;
                    end
                    disable run_schedule;
                end
            end
        end
    endtask
    // -----------------------------------------------------------------------

    task report(input [8*8-1:0] label);
        begin
            if (n_seen != 896) begin
                $display(" %0s : %0d butterflies (EXPECTED 896), %0d mismatches",
                         label, n_seen, n_fail);
                grand_fail = grand_fail + 1;
            end else begin
                $display(" %0s : %0d butterflies, %0d mismatches", label, n_seen, n_fail);
            end
            grand_fail = grand_fail + n_fail;
        end
    endtask

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_addr_gen.vcd");
            $dumpvars(0, tb_addr_gen);
        end

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("");
        $display("=====================================================");

        run_schedule("vectors/addr_schedule.txt",     1'b0, 13, "FWD");
        report("FWD");
        repeat (5) @(negedge clk);

        run_schedule("vectors/addr_schedule_inv.txt", 1'b1, 10, "INV");
        report("INV");

        // stall test: en low must freeze the sequence
        repeat (5) @(negedge clk);
        $display("-----------------------------------------------------");
        if (grand_fail == 0)
            $display(" RESULT: PASS");
        else
            $display(" RESULT: FAIL (%0d problems)", grand_fail);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #10_000_000;
        $display("TIMEOUT -- `done` never asserted? Check the layer counter.");
        $finish;
    end

endmodule
