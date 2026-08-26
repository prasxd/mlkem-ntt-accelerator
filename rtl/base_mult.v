`timescale 1ns / 1ps
// One degree-1 polynomial multiply modulo (X^2 - gamma_i).
//   c0 = a0*b0 + a1*b1*gamma ; c1 = a0*b1 + a1*b0
// Sequences 7 multiplies through ONE shared mont_mul, waiting on valid_out.
module base_mult #(
    parameter integer COEFF_W=12, parameter integer Q=3329,
    parameter integer QINV=3327,  parameter integer R2=1353   // R^2 mod q
)(
    input  wire clk, rst_n, start,
    input  wire [COEFF_W-1:0] g_mont, a0, a1, b0, b1,
    output reg  [COEFF_W-1:0] c0, c1,
    output reg  busy, done
);
    localparam ST_IDLE=4'd0, ST_A0=4'd1, ST_A1=4'd2, ST_T3=4'd3, ST_T1=4'd4,
               ST_T4=4'd5, ST_T5=4'd6, ST_T2=4'd7, ST_FIN=4'd8;

    reg [3:0] st;
    reg [COEFF_W-1:0] A0, A1, t1, t2, t3, t4, t5;
    reg [COEFF_W-1:0] ra0, ra1, rb0, rb1, rg;

    reg  mul_go;
    reg  [COEFF_W-1:0] mul_x, mul_y;
    wire [COEFF_W-1:0] mul_o;
    wire mul_v;
    mont_mul #(COEFF_W,Q,QINV) u_mul (.clk(clk), .rst_n(rst_n),
        .valid_in(mul_go), .a(mul_x), .b(mul_y), .out(mul_o), .valid_out(mul_v));

    wire [COEFF_W:0] s0 = t3 + t2;
    wire [COEFF_W:0] s1 = t4 + t5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=ST_IDLE; busy<=0; done<=0; mul_go<=0; c0<=0; c1<=0;
            A0<=0; A1<=0; t1<=0; t2<=0; t3<=0; t4<=0; t5<=0;
            ra0<=0; ra1<=0; rb0<=0; rb1<=0; rg<=0; mul_x<=0; mul_y<=0;
        end else begin
            done   <= 1'b0;
            mul_go <= 1'b0;
            case (st)
            ST_IDLE: if (start) begin
                        busy<=1'b1; ra0<=a0; ra1<=a1; rb0<=b0; rb1<=b1; rg<=g_mont;
                        mul_x<=a0; mul_y<=R2[COEFF_W-1:0]; mul_go<=1'b1; st<=ST_A0;
                     end
            ST_A0:   if (mul_v) begin A0<=mul_o;
                        mul_x<=ra1; mul_y<=R2[COEFF_W-1:0]; mul_go<=1'b1; st<=ST_A1; end
            ST_A1:   if (mul_v) begin A1<=mul_o;
                        mul_x<=A0;  mul_y<=rb0; mul_go<=1'b1; st<=ST_T3; end
            ST_T3:   if (mul_v) begin t3<=mul_o;
                        mul_x<=A1;  mul_y<=rb1; mul_go<=1'b1; st<=ST_T1; end
            ST_T1:   if (mul_v) begin t1<=mul_o;
                        mul_x<=A0;  mul_y<=rb1; mul_go<=1'b1; st<=ST_T4; end
            ST_T4:   if (mul_v) begin t4<=mul_o;
                        mul_x<=A1;  mul_y<=rb0; mul_go<=1'b1; st<=ST_T5; end
            ST_T5:   if (mul_v) begin t5<=mul_o;
                        mul_x<=t1;  mul_y<=rg;  mul_go<=1'b1; st<=ST_T2; end
            ST_T2:   if (mul_v) begin t2<=mul_o; st<=ST_FIN; end
            ST_FIN:  begin
                        c0   <= (s0 >= Q) ? s0[COEFF_W-1:0] - Q[COEFF_W-1:0] : s0[COEFF_W-1:0];
                        c1   <= (s1 >= Q) ? s1[COEFF_W-1:0] - Q[COEFF_W-1:0] : s1[COEFF_W-1:0];
                        busy <= 1'b0; done <= 1'b1; st <= ST_IDLE;
                     end
            endcase
        end
    end
endmodule
