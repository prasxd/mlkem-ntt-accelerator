`timescale 1ns / 1ps

module mont_mul #(
    parameter integer COEFF_W = 12,
    parameter integer Q       = 3329,   // modulus
    parameter integer QINV    = 3327    // -q^-1 mod 2^16   <-- note the MINUS
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    valid_in,
    input  wire [COEFF_W-1:0]      a,
    input  wire [COEFF_W-1:0]      b,
    output reg  [COEFF_W-1:0]      out,
    output reg                     valid_out
);

    localparam integer PROD_W = 2*COEFF_W;   // 24
    localparam integer MONT_W = 16;
    localparam integer WIDE_W = 28;

    // ---- Stage 1: T = a * b ------------------------------------------------
    reg [PROD_W-1:0] t_s1;
    reg              v_s1;

    // ---- Stage 2: m = low16(T) * QINV, keep low 16 -------------------------
    reg [PROD_W-1:0] t_s2;
    reg [MONT_W-1:0] m_s2;
    reg              v_s2;

    // ---- Stage 3: u = (T + m*Q) >> 16, then conditional subtract ----------
    wire [WIDE_W-1:0]  sum_s3 = t_s2 + (m_s2 * Q);
    wire [COEFF_W-1:0] u_s3   = sum_s3[WIDE_W-1:MONT_W];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_s1 <= 0;  v_s1 <= 1'b0;
            t_s2 <= 0;  m_s2 <= 0;  v_s2 <= 1'b0;
            out  <= 0;  valid_out <= 1'b0;
        end else begin
            // Stage 1
            t_s1 <= a * b;
            v_s1 <= valid_in;
            
            // Stage 2
            m_s2 <= t_s1[15:0] * QINV;
            t_s2 <= t_s1;
            v_s2 <= v_s1;
            
            // Stage 3
            out <= (u_s3 >= Q) ? (u_s3 - Q) : u_s3;
            valid_out <= v_s2;
        end
    end

endmodule