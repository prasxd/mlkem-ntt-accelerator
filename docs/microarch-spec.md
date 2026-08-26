# ML-KEM NTT Accelerator — Microarchitecture Spec v1

Freeze this before writing RTL. Revisiting these mid-implementation is what
turns a four-week project into an eight-week one.

Target: Sky130, ~100 MHz, area-efficient single-butterfly design.

---

## 1. Top-level decisions

| Decision | Choice | Rationale |
|---|---|---|
| Parallelism | **1 butterfly**, `NUM_BF` parameterised | Get it correct first. 2/4 BF is a week-4 DSE sweep, not a week-1 risk. |
| Memory | **2 banks × 128 × 12-bit**, dual-port (1R1W) | 256 coefficients, in-place |
| Banking | **`bank = ^addr`** (XOR-reduce), **`row = addr[7:1]`** | Provably zero conflicts, all 7 layers |
| Multiply | **Montgomery**, R = 2¹⁶ | No divider in the datapath |
| Add/sub reduce | **Conditional add/subtract** | Operands already < q; full Barrett unnecessary |
| Twiddles | **Montgomery domain in ROM** | `mont_mul(x, ζ_mont) = x·ζ mod q` directly, no post-scaling |
| Interface | AXI4-Lite control + AXI4-Stream data | Standard, and matches your bridge experience |
| Modes | NTT / INTT / BASEMUL | One core, three operations |

---

## 2. Datapath widths

Every width below is derived, not guessed. Put these in a `localparam` block.

```
COEFF_W   = 12    q = 3329 < 2^12
PROD_W    = 24    3328^2 = 11,075,584 < 2^24 = 16,777,216
SUM_W     = 13    a + b < 2q = 6658 < 2^13
MONT_W    = 16    R = 2^16
ADDR_W    =  8    256 coefficients
ROW_W     =  7    128 rows per bank
```

Montgomery multiply, stage by stage — `mont_mul(a, b)` returns `a·b·R⁻¹ mod q`:

```
  t   = a * b                     24 bits   (12 × 12)
  m   = (t[15:0] * QINV)[15:0]    16 bits   (16 × 16, keep low half only)
  mq  = m * Q                     28 bits   (16 × 12)
  u   = (t + mq) >> 16            12 bits   (max 3477 -- NOTE THE PLUS)
  out = (u >= Q) ? u - Q : u      12 bits   conditional subtract
```

Constants: `Q = 3329`, `QINV = 3327` (= −q⁻¹ mod 2¹⁶), `R_MOD_Q = 2285`.

**The sign matters.** Because `QINV` is *minus* q⁻¹ mod 2¹⁶, REDC **adds**
`m·Q`. The subtract form `(t − m·Q)` requires `QINV = +q⁻¹ mod 2¹⁶ = 62209`
instead. Verified over 50k random cases: the plus form with 3327 has zero
mismatches. Max `u` before the conditional subtract is **3477 < 2q**, so one
conditional subtract always suffices — never two.

Because the ROM holds ζ·R mod q, `mont_mul(x, ζ_mont) = x·ζ·R·R⁻¹ = x·ζ mod q`.
That is the whole reason for the Montgomery-domain table.

---

## 3. Butterfly pipeline

**mont_mul is 3 stages** (multiply / m-compute / reduce+cond-subtract);
the butterfly adds one more for the add/sub, so **4 total**. Balances the 12×12 and 16×16 multipliers against a ~10 ns period
on Sky130. Adjust after the first synthesis run, not before.

```
        S0        S1         S2          S3          S4
  read  │ t=a*b   │ m=t*QINV │ u=(t-mq) │ cond.sub  │ add/sub  │ write
  mem   │         │          │   >>16   │           │ + reduce │  back
```

- **CT (forward):** `t = mont_mul(b, z)`, then `a' = a+t`, `b' = a−t`
- **GS (inverse):** `a' = a+b`, then `b' = mont_mul(b−a, z)`

One module, `mode` input selects. The multiplier is shared — GS just feeds it
the difference instead of the raw operand.

`a` must be delayed 4 stages to meet `t` at S4. Use a shift register, not a
re-read: re-reading burns a memory port you do not have.

---

## 4. Memory and hazards

```verilog
wire       bank_a = ^addr_a;        // XOR-reduce, ~3 gate levels
wire [6:0] row_a  = addr_a[7:1];
```

**Why LSB banking fails:** every layer length (128…2) is even, so `j` and
`j+len` always share bit 0 — 896/896 conflicts.

**Why parity works:** within a layer, `start` is a multiple of `2·len` and
`j ∈ [start, start+len)`, so bit log₂(len) of `j` is always 0. Therefore
`j XOR (j+len) == len`, a single set bit — the two operands differ in exactly
one address bit, so their parities always differ. Verified: 0/896 conflicts.

`row = j>>1` is a bijection: indices `2r` and `2r+1` share row `r` but have
opposite parity, so exactly one lands in each bank.

**Intra-layer hazards: none.** Each coefficient is touched exactly once per
layer, so no butterfly reads an address another is writing.

**Inter-layer hazard: real.** Layer L+1 must not start reading until layer L's
last butterfly has written back. **Drain the pipeline (5 cycles) at every layer
boundary.** 7 × 5 = 35 cycles total — not worth optimising in v1.

**Implementation note:** 256 × 12 = 3072 bits. Infer a dual-port RAM in RTL;
Yosys will map it to flip-flops on Sky130 (there is no SRAM macro in the base
PDK). That is ~3072 DFFs and will dominate your area — expect it, and note it
as the headline finding. Swapping in an OpenRAM macro is a legitimate week-3
experiment with a real area/power delta to report.

---

## 5. Control FSM

```
IDLE ──start──> LOAD ──256 coeffs──> RUN ──128 BF──> DRAIN ──┐
                                      ↑                      │
                                      └──── layer < 7 ───────┘
                                              │ layer == 7
                                              ↓
                                   STORE ──256 coeffs──> DONE ──> IDLE
```

Counters:
- `layer` 0–6 (3 bits)
- `bf_cnt` 0–127 (7 bits)
- `k` 1–127, twiddle ROM address — **runs across the whole transform, never
  resets per layer**
- `stride` = 128 >> layer (forward), 2 << layer (inverse)

`j` derivation from `bf_cnt` and `layer` is the fiddly part. Cross-check
against `vectors/addr_schedule.txt`, which lists every `(layer, k, j, j+len)`
tuple in execution order. Test `addr_gen.v` against that trace **before**
connecting it to real data.

Twiddle ROM is read once per *block* (per `start`), not per butterfly — reused
`len` times. Register it; do not re-read.

---

## 6. Register map (AXI4-Lite, 32-bit)

| Offset | Name | Bits |
|---|---|---|
| 0x00 | CTRL | [0] start (W1P), [1] soft_reset |
| 0x04 | MODE | [1:0] 0=NTT, 1=INTT, 2=BASEMUL |
| 0x08 | STATUS | [0] busy, [1] done, [2] error |
| 0x0C | CYCLES | free-running cycle count of last op |

Data in/out over AXI4-Stream, 12-bit payload in a 16-bit word, one coefficient
per beat, `tlast` on coefficient 255.

`CYCLES` is not decoration — it is how you measure the DSE sweep in week 4.

---

## 7. Cycle budget

| Phase | Cycles |
|---|---|
| LOAD | 256 |
| 7 layers × 128 butterflies | 896 |
| 7 layer-boundary drains × 5 | 35 |
| STORE | 256 |
| **Total** | **≈ 1443** |

At 100 MHz: **14.4 µs per NTT.** BASEMUL is 128 pairs × 5 multiplies ≈ 640
cycles plus load/store.

Report this number against post-layout fmax. It is your headline throughput
figure.

---

## 8. Module hierarchy

Build bottom-up. **Do not start a module until the one below passes its own
testbench against golden vectors.**

| # | File | ~LoC | Test vector |
|---|---|---|---|
| 1 | `mod_reduce.v` | 80 | `tv_modmul.txt`, `tv_modaddsub.txt` |
| 2 | `butterfly.v` | 120 | `tv_butterfly_ct.txt`, `tv_butterfly_gs.txt` |
| 3 | `twiddle_rom.v` | 40 | `rom_zetas_mont.mem` |
| 4 | `coeff_mem.v` | 60 | directed R/W |
| 5 | `addr_gen.v` | 150 | `addr_schedule.txt` ← **riskiest** |
| 6 | `ntt_core.v` | 250 | `ntt_i_L0..L6.mem` per-layer |
| 7 | `base_mult.v` | 120 | `basemul_i_*.mem` |
| 8 | `ntt_top.v` | 300 | full round trip |

≈ 1120 lines. Two weeks including debug.

---

## 9. Explicitly deferred

Do not build these in v1. Each is a week-4 experiment with a measurable delta:

- Multi-butterfly (`NUM_BF` = 2, 4) and radix-4
- K-RED instead of Montgomery
- Lazy reduction (deferring reduction across layers)
- OpenRAM macro instead of inferred flops
- Power domains / UPF, DVFS
- On-the-fly twiddle generation instead of ROM

Clock gating and operand isolation, however, go in **at RTL from day one**
behind a `POWER_OPT` define, so you get a clean with/without comparison.
Retrofitting them later is painful.
