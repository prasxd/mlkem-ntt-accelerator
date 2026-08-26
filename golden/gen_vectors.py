"""
Generate every test vector the RTL will need, in $readmemh-friendly hex.

Run:  python3 gen_vectors.py [--num 8] [--seed 0xC0FFEE] [--out ../vectors]

Outputs into vectors/:
  rom_zetas.mem          128 x 12-bit  plain-domain twiddles (NTT/INTT layers)
  rom_zetas_mont.mem     128 x 12-bit  Montgomery-domain twiddles
  rom_gammas.mem         128 x 12-bit  plain-domain base-mult twiddles
  rom_gammas_mont.mem    128 x 12-bit  Montgomery-domain base-mult twiddles
  tv_modmul.txt          a b (a*b mod q)          -> tests mod_reduce.v
  tv_modaddsub.txt       a b (a+b) (a-b) mod q    -> tests mod_reduce.v
  tv_butterfly_ct.txt    z a b  a' b'             -> tests butterfly.v (CT)
  tv_butterfly_gs.txt    z a b  a' b'             -> tests butterfly.v (GS)
  addr_schedule.txt      layer len k j jlen bank_j bank_jl  -> tests addr_gen.v
  ntt_<i>_in.mem         input polynomial
  ntt_<i>_L0..L6.mem     state after each of the 7 forward layers  <-- key file
  ntt_<i>_out.mem        final NTT output (== L6)
  intt_<i>_L0..L6.mem    state after each inverse layer
  intt_<i>_out.mem       INTT output (must equal ntt_<i>_in.mem)
  basemul_<i>_a.mem / _b.mem / _out.mem
"""

import argparse
import os
import random

from ntt_ref import (mont_mul, mont_mul_hw, Q, N, ZETAS, GAMMAS, ZETAS_MONT, GAMMAS_MONT,
                     FWD_LENS, INV_LENS, ntt, intt, base_mul,
                     schoolbook_negacyclic, R_MOD_Q)


def write_mem(path, values, width_hex=3):
    with open(path, "w") as fh:
        for v in values:
            fh.write(f"{v:0{width_hex}x}\n")


def dump_roms(out):
    write_mem(os.path.join(out, "rom_zetas.mem"), ZETAS)
    write_mem(os.path.join(out, "rom_zetas_mont.mem"), ZETAS_MONT)
    write_mem(os.path.join(out, "rom_gammas.mem"), GAMMAS)
    write_mem(os.path.join(out, "rom_gammas_mont.mem"), GAMMAS_MONT)


def dump_modular_tests(out, rng, count=2000):
    """Directed + random vectors for the modular arithmetic units."""
    corners = [0, 1, 2, Q - 2, Q - 1, (Q - 1) // 2, 1728, 1729, 2285, 3328]
    pairs = [(a, b) for a in corners for b in corners]
    pairs += [(rng.randrange(Q), rng.randrange(Q)) for _ in range(count)]

    with open(os.path.join(out, "tv_modmul.txt"), "w") as fh:
        fh.write("# a b product_mod_q   (all hex, 12-bit)\n")
        for a, b in pairs:
            fh.write(f"{a:03x} {b:03x} {(a*b) % Q:03x}\n")

    with open(os.path.join(out, "tv_montmul.txt"), "w") as fh:
        fh.write("# a b montmul(a,b)=a*b*R^-1 mod q   <-- what mod_reduce.v outputs\n")
        for a, b in pairs:
            assert mont_mul_hw(a, b) == mont_mul(a, b)
            fh.write(f"{a:03x} {b:03x} {mont_mul(a, b):03x}\n")

    with open(os.path.join(out, "tv_modaddsub.txt"), "w") as fh:
        fh.write("# a b sum_mod_q diff_mod_q\n")
        for a, b in pairs:
            fh.write(f"{a:03x} {b:03x} {(a+b) % Q:03x} {(a-b) % Q:03x}\n")


def dump_butterfly_tests(out, rng, count=2000):
    """Standalone CT and GS butterfly vectors -- no memory, no control."""
    with open(os.path.join(out, "tv_butterfly_ct.txt"), "w") as fh:
        fh.write("# zeta a b  a_out b_out   (Cooley-Tukey / forward)\n")
        for _ in range(count):
            z, a, b = rng.choice(ZETAS), rng.randrange(Q), rng.randrange(Q)
            t = (z * b) % Q
            fh.write(f"{z:03x} {a:03x} {b:03x} {(a+t) % Q:03x} {(a-t) % Q:03x}\n")

    with open(os.path.join(out, "tv_butterfly_gs.txt"), "w") as fh:
        fh.write("# zeta a b  a_out b_out   (Gentleman-Sande / inverse)\n")
        for _ in range(count):
            z, a, b = rng.choice(ZETAS), rng.randrange(Q), rng.randrange(Q)
            fh.write(f"{z:03x} {a:03x} {b:03x} "
                     f"{(a+b) % Q:03x} {(z*(b-a)) % Q:03x}\n")


def bank_lsb(j):
    """Naive scheme: bank = address bit 0. (Spoiler: this fails.)"""
    return j & 1


def bank_parity(j):
    """Conflict-free scheme: bank = XOR of all address bits.

    Why it works: within a layer of length L, start is a multiple of 2L and
    j ranges over [start, start+L), so bit log2(L) of j is always 0. Therefore
    j XOR (j+L) == L, a single set bit -- the two operands of every butterfly
    differ in exactly one address bit, so their parities always differ.
    Holds for every layer, forward and inverse, with no reshuffling.

    Companion within-bank address is j >> 1, which is a bijection: indices
    2r and 2r+1 share address r but have opposite parity, so exactly one
    lands in each bank.
    """
    return bin(j).count("1") & 1


def dump_address_schedule(out):
    """Every (layer, k, j, j+len) tuple the forward NTT touches, in order.

    Feed this to addr_gen.v BEFORE wiring it to real data.
    """
    path = os.path.join(out, "addr_schedule.txt")
    conflicts_lsb = [0] * 7
    conflicts_par = [0] * 7
    with open(path, "w") as fh:
        fh.write("# layer len k_zeta j jl  bankLSB_j bankLSB_jl confLSB"
                 "  bankPAR_j bankPAR_jl confPAR  memaddr_j memaddr_jl\n")
        k = 1
        for layer, length in enumerate(FWD_LENS):
            for start in range(0, N, 2 * length):
                z_idx = k
                k += 1
                for j in range(start, start + length):
                    jl = j + length
                    la, lb = bank_lsb(j), bank_lsb(jl)
                    pa, pb = bank_parity(j), bank_parity(jl)
                    cl, cp = int(la == lb), int(pa == pb)
                    conflicts_lsb[layer] += cl
                    conflicts_par[layer] += cp
                    fh.write(f"{layer} {length:3d} {z_idx:3d} {j:3d} {jl:3d}"
                             f"  {la} {lb} {cl}"
                             f"  {pa} {pb} {cp}"
                             f"  {j >> 1:3d} {jl >> 1:3d}\n")
    return conflicts_lsb, conflicts_par


def dump_polys(out, rng, num):
    for i in range(num):
        f = [rng.randrange(Q) for _ in range(N)]
        write_mem(os.path.join(out, f"ntt_{i}_in.mem"), f)

        cap = []
        y = ntt(f, capture=cap)
        for layer, state in enumerate(cap):
            write_mem(os.path.join(out, f"ntt_{i}_L{layer}.mem"), state)
        write_mem(os.path.join(out, f"ntt_{i}_out.mem"), y)

        cap_i = []
        back = intt(y, capture=cap_i)
        for layer, state in enumerate(cap_i):
            write_mem(os.path.join(out, f"intt_{i}_L{layer}.mem"), state)
        write_mem(os.path.join(out, f"intt_{i}_out.mem"), back)
        assert back == f, f"round trip broken on poly {i}"

        g = [rng.randrange(Q) for _ in range(N)]
        ga = ntt(g)
        prod = base_mul(y, ga)
        write_mem(os.path.join(out, f"basemul_{i}_a.mem"), y)
        write_mem(os.path.join(out, f"basemul_{i}_b.mem"), ga)
        write_mem(os.path.join(out, f"basemul_{i}_out.mem"), prod)
        assert intt(prod) == schoolbook_negacyclic(f, g), \
            f"basemul disagrees with schoolbook on poly {i}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--num", type=int, default=8)
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0xC0FFEE)
    ap.add_argument("--out", default="../vectors")
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    rng = random.Random(args.seed)

    dump_roms(out)
    dump_modular_tests(out, rng)
    dump_butterfly_tests(out, rng)
    conf_lsb, conf_par = dump_address_schedule(out)
    dump_polys(out, rng, args.num)

    print(f"vectors written to {out}")
    print(f"  q={Q} n={N} R mod q={R_MOD_Q}  seed={args.seed:#x}  polys={args.num}")
    print(f"  ZETAS[1]={ZETAS[1]}  GAMMAS[0]={GAMMAS[0]}")
    print("  bank conflicts per forward layer (128 butterflies each):")
    print("    layer  len   bank=addr[0]   bank=parity(addr)")
    for layer, length in enumerate(FWD_LENS):
        print(f"    {layer:5d} {length:4d}   {conf_lsb[layer]:4d}/128       "
              f"{conf_par[layer]:4d}/128")
    print(f"  TOTAL       {sum(conf_lsb):5d}/896      {sum(conf_par):4d}/896")
    print(f"  files: {len(os.listdir(out))}")


if __name__ == "__main__":
    main()
