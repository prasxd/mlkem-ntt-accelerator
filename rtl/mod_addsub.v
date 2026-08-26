// ---------------------------------------------------------------------------
// mod_addsub.v -- modular add and subtract mod q (q = 3329)
//
//   sum  = (a + b) mod q
//   diff = (a - b) mod q
//
// Purely COMBINATIONAL -- no clock. The butterfly that instantiates this owns
// the pipeline register. Keeping it combinational makes it reusable in both
// the CT and GS paths without a latency mismatch.
//
// Precondition: a < q and b < q. Everything downstream guarantees this.
//
// EXERCISE: two assignments. ~10 lines.
// Golden vectors: vectors/tv_modaddsub.txt
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module mod_addsub #(
    parameter integer COEFF_W = 12,
    parameter integer Q       = 3329
) (
    input  wire [COEFF_W-1:0] a,
    input  wire [COEFF_W-1:0] b,
    output wire [COEFF_W-1:0] sum,
    output wire [COEFF_W-1:0] diff
);

    localparam integer SUM_W = COEFF_W + 1;   // 13

    // -----------------------------------------------------------------------
    // ADD is the easy one:
    //
    //   a + b  <  2q = 6658  <  2^13      -> 13-bit intermediate
    //   one conditional subtract is always enough (never two)
    //
    // -----------------------------------------------------------------------
    //
    // SUBTRACT is where people reach for signed arithmetic. Don't.
    //
    // a - b can go negative, and Verilog's unsigned subtract wraps around,
    // which is not the answer you want. The clean fix is to ADD THE MODULUS
    // FIRST, so the intermediate can never be negative:
    //
    //   d = a + Q - b
    //
    //   min:  a=0,      b=Q-1  ->  0    + 3329 - 3328 =    1
    //   max:  a=Q-1,    b=0    ->  3328 + 3329 - 0    = 6657  < 2^13
    //
    // So d is always in [1, 6657]: strictly positive, fits in 13 bits, and
    // one conditional subtract of Q brings it into [0, q).
    //
    // Sanity check by hand:
    //   a=0, b=0 ->  0 + 3329 - 0    = 3329, >= Q, minus Q ->    0   correct
    //   a=5, b=3 ->  5 + 3329 - 3    = 3331, >= Q, minus Q ->    2   correct
    //   a=3, b=5 ->  3 + 3329 - 5    = 3327,  < Q,         -> 3327   correct
    //                                                  (= -2 mod 3329)
    //
    // No signed types, no sign extension, no $signed(). One adder and one
    // comparator, same shape as the add path. This is the standard trick in
    // every modular arithmetic datapath -- learn it once, use it forever.
    // -----------------------------------------------------------------------

    wire [SUM_W-1:0] s_raw;   // a + b
    wire [SUM_W-1:0] d_raw;   // a + Q - b

// ================= YOUR CODE HERE =================
            
            // Step 1: Raw addition and subtraction
            assign s_raw = a + b;
            
            // CRITICAL ORDER: Add Q first to prevent unsigned underflow!
            // If you did (a - b + Q), a smaller 'a' minus a larger 'b' would 
            // wrap around to a massive positive number before Q is added.
            assign d_raw = a + Q - b;
            
            // Step 2: Conditional reduction (Modulo 3329)
            assign sum  = (s_raw >= Q) ? s_raw - Q : s_raw;
            assign diff = (d_raw >= Q) ? d_raw - Q : d_raw;

            // ==================================================

endmodule
