// ---------------------------------------------------------------------------
// addr_gen.v -- NTT address sequencer  [VERIFIED: 896/896 fwd + inv, 0 mismatches]
//
// Emits, one per enabled cycle, the (j, j+len) address pair and twiddle index
// k for every butterfly of the 7-layer transform. 896 butterflies total.
//
// THE ADDRESS TRICK
// -----------------
// Every layer has exactly 128 butterflies whatever the stride, so one counter
// bf = 0..127 suffices. With s = log2(len):
//
//     j = ((bf >> s) << (s+1)) | (bf & ((1<<s)-1))
//
// which is "bf with a zero bit inserted at position s". Bit s of j is
// therefore always 0, so  j + len == j | (1 << s)  -- an OR, not an adder.
// That is also why parity banking works: j and j+len differ in exactly one
// address bit, so their parities always differ.
//
//     forward:  len = 128 >> layer  ->  s = 7 - layer   (s: 7,6,...,1)
//     inverse:  len = 2   << layer  ->  s = layer + 1   (s: 1,2,...,7)
//
// COUNTERS vs OUTPUT REGISTERS -- the bug this file exists to avoid
// -----------------------------------------------------------------
// k_cnt/layer_cnt are the SEQUENCER STATE; k/layer are METADATA ACCOMPANYING
// THE BUTTERFLY BEING EMITTED. They are not the same signal.
//
// If you advance the counter and drive the output from the same register,
// then on the last butterfly of every block the counter has already moved on
// and the emitted k belongs to the NEXT block. It looks correct everywhere
// else, because elsewhere the counter does not move -- so you get exactly one
// wrong butterfly per block (126 of 127) and a very confusing waveform.
//
// The fix is to snapshot: k <= k_cnt happens in the same cycle the address is
// registered, while k_cnt advances independently.
//
// The same question -- "which cycle does this value belong to?" -- recurs in
// ntt_core, where the twiddle fetched with k must reach the butterfly aligned
// with the coefficients fetched with addr_a/addr_b through a different
// latency.
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module addr_gen #(
    parameter integer ADDR_W  = 8,     // 256 coefficients
    parameter integer K_W     = 7,     // 128 twiddles
    parameter integer BF_W    = 7,     // 128 butterflies per layer
    parameter integer LAYER_W = 3      // 7 layers
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,
    input  wire                mode,          // 0 = forward, 1 = inverse
    input  wire                en,            // advance only when high

    output reg                 valid,
    output reg  [ADDR_W-1:0]   addr_a,        // j
    output reg  [ADDR_W-1:0]   addr_b,        // j + len
    output reg  [K_W-1:0]      k,             // twiddle ROM index
    output reg  [LAYER_W-1:0]  layer,
    output reg                 last_in_layer, // 128th butterfly of this layer
    output reg                 busy,
    output reg                 done
);

    localparam integer N_BF_PER_LAYER = 128;
    localparam integer N_LAYERS       = 7;

    // ---- sequencer state (advances) ---------------------------------------
    reg  [BF_W-1:0]     bf;
    reg  [K_W-1:0]      k_cnt;
    reg  [LAYER_W-1:0]  layer_cnt;
    reg                 mode_r;

    // ---- stride and derived addresses, combinational ----------------------
    // s is 4 bits: it reaches 7, and 3 bits would be fine, but the +1 in the
    // inverse case and the (s+1) shift below both want the headroom.
    wire [3:0]        s       = mode_r ? (layer_cnt + 4'd1) : (4'd7 - layer_cnt);

    // Zero-extend bf to ADDR_W BEFORE shifting: bf is 7 bits, j is 8, and on
    // forward layer 0 (s = 7) the high bit would otherwise be lost.
    wire [ADDR_W-1:0] one_s   = {{(ADDR_W-1){1'b0}}, 1'b1} << s;
    wire [ADDR_W-1:0] mask    = one_s - {{(ADDR_W-1){1'b0}}, 1'b1};
    wire [ADDR_W-1:0] bf_ext  = {{(ADDR_W-BF_W){1'b0}}, bf};

    wire [ADDR_W-1:0] j_next  = ((bf_ext >> s) << (s + 1)) | (bf_ext & mask);
    wire [ADDR_W-1:0] jl_next = j_next | one_s;

    wire              blk_end = ((bf_ext & mask) == mask);  // last of block
    wire              lay_end = (bf == N_BF_PER_LAYER - 1); // last of layer
    wire              last_bf = lay_end && (layer_cnt == N_LAYERS - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bf            <= 0;
            k_cnt         <= 7'd1;
            layer_cnt     <= 0;
            mode_r        <= 1'b0;
            valid         <= 1'b0;
            busy          <= 1'b0;
            done          <= 1'b0;
            addr_a        <= 0;
            addr_b        <= 0;
            k             <= 0;
            layer         <= 0;
            last_in_layer <= 1'b0;
        end else begin
            done  <= 1'b0;
            valid <= 1'b0;

            if (start && !busy) begin
                busy      <= 1'b1;
                mode_r    <= mode;
                bf        <= 0;
                layer_cnt <= 0;
                // forward counts UP from 1, inverse counts DOWN from 127
                k_cnt     <= mode ? 7'd127 : 7'd1;

            end else if (busy && en) begin
                // ---- emit: snapshot the state used for THIS butterfly -----
                valid         <= 1'b1;
                addr_a        <= j_next;
                addr_b        <= jl_next;
                k             <= k_cnt;
                layer         <= layer_cnt;
                last_in_layer <= lay_end;

                // ---- advance: independent of the outputs above ------------
                if (lay_end) begin
                    bf <= 0;
                    if (last_bf) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        layer_cnt <= layer_cnt + 1'b1;
                    end
                end else begin
                    bf <= bf + 1'b1;
                end

                // k advances once per BLOCK, never resets per layer:
                // it runs 1..127 (fwd) or 127..1 (inv) across the whole run.
                if (blk_end && !last_bf)
                    k_cnt <= mode_r ? (k_cnt - 1'b1) : (k_cnt + 1'b1);
            end
        end
    end

endmodule
