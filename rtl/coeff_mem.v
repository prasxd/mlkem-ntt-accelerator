`timescale 1ns / 1ps
// 2 banks x 128 x 12, parity-banked, TRUE DUAL PORT (1R1W per bank).
// Separate read and write address paths: the NTT pipeline reads for butterfly
// n and writes back butterfly n-WB_LAT in the same cycle.
module coeff_mem #(
    parameter integer COEFF_W=12, parameter integer ADDR_W=8,
    parameter integer ROW_W=7,    parameter integer DEPTH=128
)(
    input  wire clk, rst_n,
    // read ports (1-cycle latency)
    input  wire               ren,              // read enable: q holds when low
    input  wire [ADDR_W-1:0]  raddr_a, raddr_b,
    output wire [COEFF_W-1:0] rdata_a, rdata_b,
    // write ports
    input  wire [ADDR_W-1:0]  waddr_a, waddr_b,
    input  wire               we_a, we_b,
    input  wire [COEFF_W-1:0] wdata_a, wdata_b
);
    wire rbank_a = ^raddr_a, rbank_b = ^raddr_b;
    wire wbank_a = ^waddr_a, wbank_b = ^waddr_b;
    wire [ROW_W-1:0] rrow_a = raddr_a[ADDR_W-1:1], rrow_b = raddr_b[ADDR_W-1:1];
    wire [ROW_W-1:0] wrow_a = waddr_a[ADDR_W-1:1], wrow_b = waddr_b[ADDR_W-1:1];

    reg [COEFF_W-1:0] bank0 [0:DEPTH-1];
    reg [COEFF_W-1:0] bank1 [0:DEPTH-1];
    reg [COEFF_W-1:0] q0, q1;

    // read routing: bank0 served by whichever read port targets it
    wire [ROW_W-1:0] rrow0 = (rbank_a==1'b0) ? rrow_a : rrow_b;
    wire [ROW_W-1:0] rrow1 = (rbank_a==1'b1) ? rrow_a : rrow_b;
    // write routing, independently
    wire               we0  = (wbank_a==1'b0) ? we_a    : we_b;
    wire [ROW_W-1:0]   wrow0= (wbank_a==1'b0) ? wrow_a  : wrow_b;
    wire [COEFF_W-1:0] wd0  = (wbank_a==1'b0) ? wdata_a : wdata_b;
    wire               we1  = (wbank_a==1'b1) ? we_a    : we_b;
    wire [ROW_W-1:0]   wrow1= (wbank_a==1'b1) ? wrow_a  : wrow_b;
    wire [COEFF_W-1:0] wd1  = (wbank_a==1'b1) ? wdata_a : wdata_b;

    always @(posedge clk) begin
        if (we0) bank0[wrow0] <= wd0;
        if (ren) q0 <= bank0[rrow0];
    end
    always @(posedge clk) begin
        if (we1) bank1[wrow1] <= wd1;
        if (ren) q1 <= bank1[rrow1];
    end

    reg rbank_a_d, rbank_b_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rbank_a_d<=0; rbank_b_d<=0; end
        else if (ren) begin rbank_a_d<=rbank_a; rbank_b_d<=rbank_b; end
    end
    assign rdata_a = rbank_a_d ? q1 : q0;
    assign rdata_b = rbank_b_d ? q1 : q0;
endmodule
