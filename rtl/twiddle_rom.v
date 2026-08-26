// ---------------------------------------------------------------------------
// twiddle_rom.v -- 128 x 12-bit twiddle ROM, MONTGOMERY DOMAIN
//
// Given complete -- there is nothing to learn from stubbing a ROM.
//
// Contents: ZETAS_MONT[k] = (zeta^brv7(k) * R) mod q,  R = 2^16.
// Storing them pre-scaled by R is what makes mont_mul(x, zeta_mont) return
// x*zeta mod q with no post-scaling anywhere in the datapath.
//
// Addressing: `k` runs 1..127 across the WHOLE transform and never resets
// per layer. Entry 0 is unused by the NTT (it holds zeta^0 = R mod q = 2285)
// but is kept so the ROM index equals k directly.
//
// The address generator reads this ONCE PER BLOCK (per `start`), not once per
// butterfly -- the same twiddle is reused `len` times. Register it and hold.
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module twiddle_rom #(
    parameter integer COEFF_W  = 12,
    parameter integer DEPTH    = 128,
    parameter integer ADDR_W   = 7,
    parameter         INIT_FILE = "vectors/rom_zetas_mont.mem"
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                en,
    input  wire [ADDR_W-1:0]   addr,     // = k
    output reg  [COEFF_W-1:0]  dout      // 1-cycle latency
);

    reg [COEFF_W-1:0] mem [0:DEPTH-1];

    initial begin
        $readmemh(INIT_FILE, mem);
`ifndef SYNTHESIS
        if (mem[1] !== 12'ha0b) begin
            // ZETAS_MONT[1] = 1729 * 2285 mod 3329 = 2571 = 0xa0b
            $display("WARNING: twiddle_rom: mem[1]=%0h, expected a0b.", mem[1]);
            $display("         Is INIT_FILE=%0s present, and are you running", INIT_FILE);
            $display("         from the PROJECT ROOT? Did you load the PLAIN");
            $display("         table (rom_zetas.mem) by mistake?");
        end
`endif
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     dout <= {COEFF_W{1'b0}};
        else if (en)    dout <= mem[addr];
    end

endmodule
