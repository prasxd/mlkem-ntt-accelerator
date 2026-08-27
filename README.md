# ML-KEM (FIPS 203) NTT Accelerator — RTL to GDSII on Sky130

A hardware accelerator for the Number-Theoretic Transform used in ML-KEM
(CRYSTALS-Kyber), taken from mathematical specification through RTL, verification,
synthesis, and full physical implementation to a DRC/LVS-clean GDSII layout on
the SkyWater 130 nm open PDK.

<!-- TODO: layout screenshot
     librelane --last-run --flow openinklayout ./config.yaml
     then: docs/img/layout.png -->

---

## Results

| Metric | Value |
|---|---|
| Process | SkyWater Sky130A (`sky130_fd_sc_hd`) |
| Die area | 461,991 µm² (~680 × 680 µm) |
| Core utilisation | 52.3% |
| Standard cells | 11,222 |
| Flip-flops | 3,528 |
| **Max frequency** | **45.5 MHz** (22 ns, closes at all 9 corners) |
| Latency | 1,462 cycles → **32.2 µs** per 256-point NTT |
| Power | 72.3 mW @ 45.5 MHz |
| **Energy per NTT** | **2.32 µJ** |
| Worst IR drop | 6.24 mV on 1.8 V (0.35%) |
| DRC / LVS / Antenna | **Pass / Pass / Pass** |
| Setup / hold violations | 0 / 0 |

LVS: `Circuit 1 contains 20748 devices, Circuit 2 contains 20748 devices.
Circuits match uniquely.`

---

## Finding: delay-repair cells were costing 36% of achievable frequency

While reading the post-place-and-route timing report, five cells on the critical
path stood out:

```
fanout1834  clkdlybuf4s25_1   0.956 ns
fanout1831  clkdlybuf4s25_1   1.255 ns
fanout1830  dlymetal6s4s_1    1.117 ns
fanout98    dlymetal6s4s_1    1.003 ns
fanout97    clkdlybuf4s15_2   0.850 ns
                              ────────
                              5.181 ns
```

`clkdlybuf*` and `dlymetal*` are **intentional delay cells** — they exist in the
Sky130 library to *add* delay for hold-time repair. OpenROAD's resizer was
selecting them as general-purpose buffers during setup repair. A comparable
real buffer on the same path (`buf_2`, `fanout357`) drove an identical fanout of
10 in 0.475 ns — 2–2.6× faster.

Excluding them via `EXTRA_EXCLUDED_CELLS`:

| | Default | Delay cells excluded |
|---|---|---|
| Setup slack @ 24 ns, `ss_100C_1v60` | **−1.691 ns** | **+2.690 ns** |
| Closing period | 30 ns | **22 ns** |
| Max frequency | 33.3 MHz | **45.5 MHz** (+36.5%) |
| Energy per NTT | 2.63 µJ | **2.32 µJ** (−12%) |
| I/O constraints | generic fallback SDC | 20% of period, both directions |

No RTL was modified. Constraints were *tightened* at the same time — the
default runs used LibreLane's generic fallback SDC with no I/O delays, while the
improved runs use a hand-written SDC with 4.8 ns of input and output delay.

This corresponds to
[OpenLane issue #1787](https://github.com/The-OpenROAD-Project/OpenLane/issues/1787),
which reports the same behaviour.

**Trade-off:** the exclusion is not free. At 22 ns, max-slew and max-capacitance
violations appear at the three `ss` corners; they are absent at 24 ns. Removing
the delay cells removes drive-strength options the resizer was using, and below
~24 ns it can no longer repair every load. Two valid operating points:

| Configuration | Frequency | Electrical checks |
|---|---|---|
| 22 ns, aggressive | 45.5 MHz | max-slew / max-cap violations at `ss` |
| 24 ns, conservative | 41.7 MHz | clean |

---

## Finding: energy per operation is frequency-invariant

Eight physical implementation runs across two netlist configurations:

| Netlist | Period | Power | Energy / NTT |
|---|---|---|---|
| Default | 20 ns | 90.11 mW | 2.63 µJ |
| Default | 24 ns | 74.95 mW | 2.63 µJ |
| Default | 28 ns | 64.25 mW | 2.63 µJ |
| Default | 29 ns | 62.04 mW | 2.63 µJ |
| Default | 30 ns | 59.97 mW | 2.63 µJ |
| Delay cells excluded | 20 ns | 79.52 mW | 2.32 µJ |
| Delay cells excluded | 21 ns | 75.71 mW | 2.32 µJ |
| Delay cells excluded | 22 ns | 72.27 mW | 2.32 µJ |
| Delay cells excluded | 24 ns | 66.25 mW | 2.32 µJ |

Two plateaus, each flat across frequency, separated only by a netlist change.
Energy per operation is set by how much capacitance is switched, not how fast.
**Frequency scaling cannot improve this design's efficiency; only reducing
switched nodes can.**

---

## Finding: flip-flop memory dominates the design

The 256-coefficient working memory is implemented in flip-flops — base Sky130
ships no SRAM macro in the standard cell library.

| | |
|---|---|
| Storage | 256 × 12 bits = 3,072 bits |
| Flip-flops used | 3,096 (3,072 storage + 24 read registers) |
| Area (post-synthesis) | 92,973 µm² |
| **Share of total cell area** | **62.8%** |
| **Cost per stored bit** | **30.03 µm²** |

The same decision appears three times in the results:

1. **Area** — 62.8% of the chip
2. **Clock** — `[GRT-0281] Net clk has a large fanout of 3529 terminals`, requiring
   569 clock buffers and 47 clock inverters
3. **Energy** — a fixed number of switched nodes per transform, which is why
   energy is frequency-invariant

Only about half of the memory's cell count is storage; the rest is the 127-deep
read multiplexer tree and write-address decoder per bank — infrastructure a real
SRAM macro provides for free. Replacing it with an OpenRAM dual-port macro is the
highest-value remaining optimisation.

---

## The mathematics

The NTT is not a cryptographic primitive — it is a DFT over a finite field.
Twiddle factors are integers mod a prime instead of complex exponentials, so the
arithmetic is exact and there is no rounding error.

| Constant | Value | Role |
|---|---|---|
| `q` | 3329 | prime modulus, 12 bits |
| `n` | 256 | polynomial degree |
| `ζ` | 17 | primitive 256th root of unity mod q |
| `ζ¹²⁸` | 3328 = −1 | makes the transform negacyclic |
| `128⁻¹` | 3303 | final INTT scaling |
| `R` | 2¹⁶ | Montgomery radix |
| `QINV` | 3327 | −q⁻¹ mod 2¹⁶ |
| `R² mod q` | 1353 | Montgomery domain conversion |

### Seven layers, not eight

```
3329 − 1 = 3328 = 2⁸ × 13
```

The multiplicative group mod 3329 has order 3328. The largest power of two
dividing it is 2⁸ = 256, so a primitive **256th** root of unity exists (ζ = 17)
but a **512th** root does not.

Each NTT layer splits a polynomial modulus by taking a square root of its
constant. After seven layers the factors are 128 quadratics `X² − γᵢ`; splitting
those further would require square roots of odd powers of ζ, which are 512th
roots of unity and do not exist mod 3329.

Consequence: pointwise multiplication is a **2×2 base multiplication** modulo
`X² − γᵢ`, not a scalar multiply:

```
c₀ = a₀b₀ + a₁b₁γᵢ
c₁ = a₀b₁ + a₁b₀
```

Five modular multiplies per coefficient pair instead of one.

### Conflict-free memory banking

Butterfly operands are always `(j, j+len)` with `len ∈ {128, 64, …, 2}`. Every
stride is even, so `j` and `j+len` always share bit 0 — banking on `addr[0]`
conflicts on **896 of 896** butterflies.

Banking on **parity** (`bank = ^addr`) gives **0 of 896** conflicts:

> Within a layer of length `L`, `start` is a multiple of `2L` and
> `j ∈ [start, start+L)`, so bit log₂(L) of `j` is always 0. Therefore
> `j XOR (j+L) == L` — a single set bit. The two operands differ in exactly one
> address bit, so their parities always differ. This holds for all seven layers,
> forward and inverse, with no reshuffling.

The companion row address `j >> 1` is a bijection: indices `2r` and `2r+1` share
row `r` but have opposite parity, so exactly one lands in each bank.

The same fact drives the address generator. With `s = log₂(len)`:

```
j = ((bf >> s) << (s+1)) | (bf & ((1<<s)-1))     // insert zero bit at position s
j + len == j | (1 << s)                          // an OR, not an adder
```

Bit `s` of `j` is always zero, which is *why* the parities differ. The banking
scheme and the address generator are two views of one structural property.

---

## Architecture

```
ntt_top          AXI4-Lite control + AXI4-Stream data
└── ntt_core     FSM: IDLE → LOAD → RUN → SCALE → STORE → DONE
    ├── addr_gen      (j, j+len, k) sequencer, 896 butterflies
    ├── twiddle_rom   128 × 12-bit, Montgomery domain
    ├── coeff_mem     2 banks × 128 × 12, parity-banked, 1R1W
    └── butterfly     shared-multiplier CT / GS
        ├── mont_mul      3-stage Montgomery multiplier
        └── mod_addsub ×2 combinational mod add/sub
base_mult        2×2 degree-1 polynomial multiply (standalone, verified)
```

**662 lines of RTL.**

### Design decisions

**Shared multiplier across CT and GS.** In both modes exactly one 12-bit value
must survive the multiply latency — `a` for Cooley-Tukey, `a+b` for
Gentleman-Sande. One 3-deep delay line carrying `mode ? (a+b) : a`, one mux on
the multiplier input carrying `mode ? (b−a) : b`. Both derived values come from a
single `mod_addsub` instance fed `(b, a)` rather than `(a, b)`. Cost: 36 flops
instead of a second 12×12 multiplier.

**Montgomery-domain twiddles.** The ROM stores `ζ·R mod q`, so
`mont_mul(x, ζ_mont)` returns `x·ζ mod q` directly — the `R⁻¹` that Montgomery
introduces cancels the `R` baked into the table. No post-scaling anywhere.

**Subtraction without signed arithmetic.** `d = a + Q − b` lands in [1, 6657] for
all `a, b ∈ [0, q)` — always positive, 13 bits, one conditional subtract. Verified
over 200,100 pairs including all corner combinations.

**INTT scaling reuses the butterfly.** A GS butterfly with `a = 0` computes
`z·(b−0) = z·b`, so feeding `(0, x, NINV_MONT)` is a plain modular multiply.
`NINV_MONT = 3303 × 2285 mod 3329 = 512`. No extra multiplier.

**True dual-port memory.** Once the pipeline is full, the core reads for butterfly
*n* and writes back butterfly *n−5* in the same cycle, and each bank sees one read
plus one write. The port count fell out of the pipeline depth, not from choice.

**Read enable, not just address hold.** Stalling a synchronous read by freezing the
address does not hold the data — the address is presented again, the memory reads
it again, and the fetched beat is clobbered. `coeff_mem` has a `ren` input;
this maps directly onto an SRAM macro's chip-enable.

**Self-timed inter-layer drain.** Rather than hard-coding a wait, the core counts
in-flight butterflies and holds `addr_gen`'s enable low until the count reaches
zero. Robust to any change in butterfly or memory latency.

---

## Verification

Every module is checked against a golden model derived from FIPS 203 and
cross-validated against `kyber-py`.

| Module | Vectors | Result |
|---|---|---|
| `mont_mul` | 2,100 (corners + random) | 2,100 pass |
| `mod_addsub` | 2,100 | 2,100 pass |
| `butterfly` | 4,000 (2,000 CT + 2,000 GS) | 4,000 pass |
| `coeff_mem` | 896 real butterfly address pairs | 896 pass, 0 bank conflicts |
| `addr_gen` | 1,792 (896 forward + 896 inverse) | 0 mismatches |
| `addr_gen` under random stall | 896 | 0 mismatches |
| `base_mult` | 2,000 degree-1 pairs | 2,000 pass |
| `ntt_core` | 32 end-to-end (8 polys × NTT/INTT × with/without backpressure) | 0 errors |
| `ntt_top` | 12 cases via AXI4-Lite + AXI4-Stream | 0 errors |

The golden model self-checks three ways:

1. **Round trip** — `intt(ntt(f)) == f` over 50 random polynomials
2. **Schoolbook** — `intt(base_mul(ntt(a), ntt(b)))` against naive O(n²)
   negacyclic multiplication. This is the check that catches a broken `base_mul`;
   the round trip alone does not, because forward and inverse errors cancel.
3. **Cross-validation** — against `kyber-py`, independently written from the same
   specification

Per-layer intermediate states are dumped for all 7 forward and 7 inverse layers,
so an RTL failure identifies *which layer* broke in a single simulation.

---

## Reproducing

### Simulation

```bash
# Golden model + test vectors (169 files)
python3 golden/ntt_ref.py
python3 golden/gen_vectors.py --num 8 --out vectors

# Full regression
for t in mont_mul mod_addsub butterfly coeff_mem addr_gen base_mult ntt_core ntt_top; do
  iverilog -g2012 -Wall -o build/tb_$t.vvp tb/tb_$t.v rtl/*.v
  vvp build/tb_$t.vvp
done
```

### Physical implementation

Requires [LibreLane](https://github.com/librelane/librelane) and the Sky130 PDK
via `ciel`.

```bash
cd ~/tools/librelane && nix-shell
python3 -m librelane --pdk-root $HOME/.ciel ./config.yaml
```

Configuration is in `config.yaml`; timing constraints in `scripts/ntt_top.sdc`.
Sign-off artifacts for the final run are in `docs/signoff/final_22ns/`.

**Note:** run from a clean shell. OSS CAD Suite exports `VERILATOR_ROOT`, which
will cause LibreLane's Verilator step to fail if the two environments are mixed.

---

## Repository layout

```
golden/     Python reference model and test-vector generator
rtl/        9 Verilog modules, 662 lines
tb/         Self-checking testbenches
vectors/    169 generated test-vector files
scripts/    SDC timing constraints
docs/       Microarchitecture spec, synthesis logs, sign-off artifacts
config.yaml LibreLane configuration
```

---

## Known limitations

**Power figures are vectorless.** No SAIF was supplied, so switching activity is
assumed rather than derived from a real ML-KEM workload. Activity-based power
requires gate-level simulation of the post-layout netlist. The 2.32 µJ figure is
an estimate, not a measurement — though its invariance across four runs suggests
it is at least self-consistent.

**Run-to-run variance is roughly ±1 ns.** Each LibreLane run re-synthesises,
re-places and re-routes; the critical path is not stable between runs. Reported
frequencies are single-run results, not averaged. One observed case: relaxing the
period by 4 ns improved worst slack by only 0.27 ns.

**Max-slew and max-capacitance violations at 22 ns.** Present at the three `ss`
corners in the aggressive configuration; absent at 24 ns. Setup and hold are
clean at both.

**`base_mult` is verified but not integrated.** It passes 2,000 golden vectors
standalone. Integration into `ntt_top` needs no second memory — the second
operand polynomial can stream in over AXI while the first is read from
`coeff_mem` — but this is not implemented.

**Base multiplication is 30 cycles per pair.** The FSM issues one multiply and
waits for `valid_out`, leaving the multiplier idle 3 cycles in 4. Only two of the
seven multiplies are genuinely dependent; a static schedule should reach ~10
cycles per pair, and pipelining across pairs ~7.

---

## Future work

In descending order of expected value:

1. **OpenRAM SRAM macro** for the coefficient memory — attacks the 62.8% area
   share, the 3,529-terminal clock net, and the energy floor simultaneously. The
   macros ship with the Sky130 PDK.
2. **Clock gating** — the memory write-enables are already explicit, making the
   3,529-sink clock net the largest available dynamic-power reduction.
3. **Activity-based power** — SAIF from post-layout gate-level simulation of a
   real ML-KEM workload, replacing the vectorless estimate.
4. **Design-space exploration** — sweep butterfly count (1/2/4), radix (2/4), and
   reduction algorithm (Montgomery / Barrett / K-RED) for area-energy-latency
   Pareto curves.
5. **UPF power intent** — power domains, isolation, retention, and a PMU
   shutdown sequence.

---

## References

- FIPS 203, *Module-Lattice-Based Key-Encapsulation Mechanism Standard*
- [`pq-crystals/kyber`](https://github.com/pq-crystals/kyber) — reference implementation
- [`GiacomoPope/kyber-py`](https://github.com/GiacomoPope/kyber-py) — Python reference used for cross-validation
- [LibreLane](https://github.com/librelane/librelane) — RTL-to-GDSII flow
- [SkyWater Sky130 PDK](https://github.com/google/skywater-pdk)
