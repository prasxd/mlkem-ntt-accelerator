// ---------------------------------------------------------------------------
// butterfly.v -- Cooley-Tukey / Gentleman-Sande butterfly for ML-KEM NTT
//
//   mode = 0  (CT, forward NTT):   t = b * z          (Montgomery)
//                                  a_out = a + t
//                                  b_out = a - t
//
//   mode = 1  (GS, inverse NTT):   a_out = a + b
//                                  b_out = (b - a) * z (Montgomery)
//
// ONE multiplier is shared between both modes. That is the whole design
// problem here: the multiply happens at a DIFFERENT POINT in the dataflow
// for each mode -- after the add/sub for CT, before it for GS.
//
// LATENCY = 4 cycles  (mont_mul is 3, plus 1 output register).
//
// EXERCISE: the muxes and the delay line. ~40 lines.
// Golden vectors: vectors/tv_butterfly_ct.txt, tv_butterfly_gs.txt
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module butterfly #(
    parameter integer COEFF_W = 12,
    parameter integer Q       = 3329,
    parameter integer QINV    = 3327,
    parameter integer MUL_LAT = 3      // mont_mul pipeline depth
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                valid_in,
    input  wire                mode,       // 0 = CT (fwd), 1 = GS (inv)
    input  wire [COEFF_W-1:0]  z_mont,     // twiddle, MONTGOMERY DOMAIN
    input  wire [COEFF_W-1:0]  a,
    input  wire [COEFF_W-1:0]  b,
    output reg  [COEFF_W-1:0]  a_out,
    output reg  [COEFF_W-1:0]  b_out,
    output reg                 valid_out
);

    // =======================================================================
    // THE KEY INSIGHT -- read this before writing anything.
    //
    // Naively you would build two datapaths and mux between them. That costs
    // two multipliers, and the multiplier is by far the largest thing here.
    //
    // Instead, notice that in BOTH modes exactly ONE 12-bit value has to
    // survive the 3-cycle multiply latency to be combined with the product:
    //
    //   CT:  `a`      survives, then  a_out = a + t,  b_out = a - t
    //   GS:  `a + b`  survives, then  a_out = a + b,  b_out = t
    //
    // So you need only ONE 3-deep delay line, carrying whichever value the
    // current mode requires:
    //
    //       keep = mode ? (a + b) : a
    //
    // and only ONE mux on the multiplier input:
    //
    //       mul_operand = mode ? (b - a) : b
    //
    // Both (a+b) and (b-a) come from a SINGLE mod_addsub instance -- feed it
    // (b, a) rather than (a, b), so `sum` = b+a and `diff` = b-a.
    //
    // Result: 1 multiplier, 2 cheap add/sub blocks, one 12-bit x 3 delay
    // line. That is roughly 36 flops instead of a second 12x12 multiplier.
    // =======================================================================

    // ---- input add/sub: note the (b, a) ordering, NOT (a, b) --------------
    wire [COEFF_W-1:0] sum_in;    // = b + a
    wire [COEFF_W-1:0] diff_in;   // = b - a

    mod_addsub #(.COEFF_W(COEFF_W), .Q(Q)) u_addsub_in (
        .a    (b),
        .b    (a),
        .sum  (sum_in),
        .diff (diff_in)
    );

    // ---- multiplier operand mux -------------------------------------------
    wire [COEFF_W-1:0] mul_operand;

    // ================= YOUR CODE HERE (1 of 3) =================
    assign mul_operand = mode ? diff_in : b;
    // ===========================================================

    // ---- shared Montgomery multiplier -------------------------------------
    wire [COEFF_W-1:0] t;
    wire               v_mul;

    mont_mul #(.COEFF_W(COEFF_W), .Q(Q), .QINV(QINV)) u_mul (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .a         (mul_operand),
        .b         (z_mont),
        .out       (t),
        .valid_out (v_mul)
    );

    // ---- delay line: MUL_LAT deep, carries `keep` and `mode` ---------------
    //
    // `keep` must arrive at the output stage in the SAME cycle as `t`.
    // mont_mul registers its output, so a value entering the delay line on
    // the same edge as valid_in must come out MUL_LAT cycles later.
    //
    // `mode` is delayed too. It is static during a transform, so strictly you
    // could use it undelayed -- but delaying it costs 3 flops and makes the
    // block correct even if modes are ever interleaved. Do the cheap thing.

    wire [COEFF_W-1:0] keep;
    reg  [COEFF_W-1:0] keep_dly [0:MUL_LAT-1];
    reg                mode_dly [0:MUL_LAT-1];
    integer            i;

    // ================= YOUR CODE HERE (2 of 3) =================
    assign keep = mode ? sum_in : a;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < MUL_LAT; i = i + 1) begin
                keep_dly[i] <= 0;
                mode_dly[i] <= 1'b0;
            end
        end else begin
            keep_dly[0] <= keep;
            mode_dly[0] <= mode;
            for (i = 1; i < MUL_LAT; i = i + 1) begin
                keep_dly[i] <= keep_dly[i-1];
                mode_dly[i] <= mode_dly[i-1];
            end
        end
    end
    // ===========================================================

    wire [COEFF_W-1:0] keep_d = keep_dly[MUL_LAT-1];
    wire               mode_d = mode_dly[MUL_LAT-1];

    // ---- output add/sub: combines the survivor with the product -----------
    wire [COEFF_W-1:0] ct_a;    // = keep_d + t
    wire [COEFF_W-1:0] ct_b;    // = keep_d - t

    mod_addsub #(.COEFF_W(COEFF_W), .Q(Q)) u_addsub_out (
        .a    (keep_d),
        .b    (t),
        .sum  (ct_a),
        .diff (ct_b)
    );

    // ---- output register (the 4th stage) -----------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out     <= 0;
            b_out     <= 0;
            valid_out <= 1'b0;
        end else begin
            // ================= YOUR CODE HERE (3 of 3) =================
            if (mode_d == 1'b0) begin
                // CT Mode (Forward NTT)
                a_out <= ct_a;
                b_out <= ct_b;
            end else begin
                // GS Mode (Inverse NTT)
                a_out <= keep_d;
                b_out <= t;
            end
            
            valid_out <= v_mul;
            // ===========================================================
        end
    end

endmodule