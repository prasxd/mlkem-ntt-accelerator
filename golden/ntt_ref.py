"""
ML-KEM (FIPS 203) NTT reference model -- written directly from the spec.

This is the *hardware designer's* view of the transform. No cryptography here:
it is a 7-layer negacyclic NTT over Z_q[X]/(X^256+1) with q = 3329.

Key facts to keep in your head while writing RTL:
  * q = 3329 fits in 12 bits. Coefficients are stored as 12-bit unsigned.
  * zeta = 17 is a primitive 256th root of unity mod q.
  * The transform is INCOMPLETE: 7 layers, not 8. q has a 256th root of unity
    but no 512th one, so the recursion bottoms out at 128 degree-1 polynomials.
    Pointwise multiply is therefore a 2x2 base multiplication, NOT a scalar mul.
  * Twiddles are indexed in BIT-REVERSED order (7-bit reversal).
"""

Q = 3329          # prime modulus
N = 256           # polynomial degree
ZETA = 17         # primitive 256th root of unity mod Q
NINV = 3303       # 128^-1 mod Q  (128 = 2^7 = number of layers' worth of 2x growth)

# Montgomery constants (Kyber reference uses R = 2^16)
R_BITS = 16
R_MOD_Q = (1 << R_BITS) % Q          # 2285
QINV = pow(-Q, -1, 1 << R_BITS)      # -q^-1 mod 2^16 = 3327


R_INV = pow(1 << R_BITS, -1, Q)      # 169


def mont_mul(a, b):
    """Mathematical spec of the hardware multiplier: a*b*R^-1 mod q."""
    return (a * b * R_INV) % Q


def mont_mul_hw(a, b):
    """Bit-accurate model of mod_reduce.v. Mirror this in Verilog exactly.

    NOTE the PLUS: QINV here is -q^-1 mod 2^16 (= 3327), so REDC adds m*Q.
    The subtract form requires QINV = +q^-1 mod 2^16 (= 62209) instead.
    """
    T = a * b                                   # 24 bits
    m = ((T & 0xFFFF) * QINV) & 0xFFFF          # 16 bits, low half only
    u = (T + m * Q) >> R_BITS                   # 12 bits, max 3477
    return u - Q if u >= Q else u


def brv7(i: int) -> int:
    """Reverse the low 7 bits of i. Twiddle ROM addressing depends on this."""
    return int(f"{i:07b}"[::-1], 2)


# Twiddle tables ----------------------------------------------------------
# ZETAS[k] is consumed sequentially by the layer/start loops (k = 1..127).
ZETAS = [pow(ZETA, brv7(i), Q) for i in range(128)]

# GAMMAS[i] is the twiddle for base multiplication of the i-th degree-1 pair.
GAMMAS = [pow(ZETA, 2 * brv7(i) + 1, Q) for i in range(128)]

# Montgomery-domain versions (what you actually store in the ROM if the
# butterfly uses a Montgomery multiplier).
ZETAS_MONT = [(z * R_MOD_Q) % Q for z in ZETAS]
GAMMAS_MONT = [(g * R_MOD_Q) % Q for g in GAMMAS]

# Layer lengths. Forward = decimation in time (Cooley-Tukey).
FWD_LENS = [128, 64, 32, 16, 8, 4, 2]
INV_LENS = [2, 4, 8, 16, 32, 64, 128]


def ntt(f, capture=None):
    """Forward NTT, FIPS 203 Algorithm 9. Cooley-Tukey butterflies.

    capture: if a list is passed, the full 256-coeff state is appended after
    each of the 7 layers. These are your RTL comparison points.
    """
    f = list(f)
    k = 1
    for length in FWD_LENS:
        for start in range(0, N, 2 * length):
            z = ZETAS[k]
            k += 1
            for j in range(start, start + length):
                t = (z * f[j + length]) % Q
                f[j + length] = (f[j] - t) % Q
                f[j] = (f[j] + t) % Q
        if capture is not None:
            capture.append(list(f))
    return f


def intt(f, capture=None):
    """Inverse NTT, FIPS 203 Algorithm 10. Gentleman-Sande butterflies."""
    f = list(f)
    k = 127
    for length in INV_LENS:
        for start in range(0, N, 2 * length):
            z = ZETAS[k]
            k -= 1
            for j in range(start, start + length):
                t = f[j]
                f[j] = (t + f[j + length]) % Q
                f[j + length] = (z * (f[j + length] - t)) % Q
        if capture is not None:
            capture.append(list(f))
    f = [(x * NINV) % Q for x in f]
    return f


def base_mul(a, b):
    """Pointwise multiply in the NTT domain, FIPS 203 Algorithm 11/12.

    Each pair (a[2i], a[2i+1]) is a degree-1 polynomial a0 + a1*X, multiplied
    modulo (X^2 - gamma_i). THIS is the incomplete-NTT consequence.
    """
    c = [0] * N
    for i in range(128):
        a0, a1 = a[2 * i], a[2 * i + 1]
        b0, b1 = b[2 * i], b[2 * i + 1]
        g = GAMMAS[i]
        c[2 * i] = (a0 * b0 + a1 * b1 * g) % Q
        c[2 * i + 1] = (a0 * b1 + a1 * b0) % Q
    return c


def schoolbook_negacyclic(a, b):
    """Naive O(n^2) multiply in Z_q[X]/(X^256+1). Ground truth for base_mul."""
    c = [0] * N
    for i in range(N):
        for j in range(N):
            k = i + j
            if k < N:
                c[k] = (c[k] + a[i] * b[j]) % Q
            else:
                c[k - N] = (c[k - N] - a[i] * b[j]) % Q
    return [x % Q for x in c]


# Self-checks -------------------------------------------------------------

def _selfcheck():
    import random
    random.seed(0xC0FFEE)

    assert pow(ZETA, 128, Q) == Q - 1, "zeta^128 must be -1 mod q"
    assert pow(ZETA, 256, Q) == 1, "zeta must be a 256th root of unity"
    assert (128 * NINV) % Q == 1, "NINV wrong"
    assert (Q * QINV) % (1 << R_BITS) == ((1 << R_BITS) - 1), "QINV wrong"

    for _ in range(3000):
        a, b = random.randrange(Q), random.randrange(Q)
        assert mont_mul_hw(a, b) == mont_mul(a, b), "mont_mul_hw != spec"

    for _ in range(50):
        f = [random.randrange(Q) for _ in range(N)]
        assert intt(ntt(f)) == f, "NTT/INTT round trip failed"

    for _ in range(10):
        a = [random.randrange(Q) for _ in range(N)]
        b = [random.randrange(Q) for _ in range(N)]
        fast = intt(base_mul(ntt(a), ntt(b)))
        slow = schoolbook_negacyclic(a, b)
        assert fast == slow, "base_mul does not match schoolbook"

    return True


def _check_against_kyber_py():
    """Cross-validate against the independently-written kyber-py package."""
    import random
    from kyber_py.polynomials.polynomials import PolynomialRing

    random.seed(1234)
    R = PolynomialRing()

    assert list(R.ntt_zetas) == ZETAS, "zeta table mismatch vs kyber-py"

    for _ in range(30):
        coeffs = [random.randrange(Q) for _ in range(N)]
        mine = ntt(coeffs)
        theirs = R(list(coeffs)).to_ntt().coeffs
        assert mine == list(theirs), "forward NTT mismatch vs kyber-py"

        assert intt(mine) == list(R(list(coeffs)).to_ntt().from_ntt().coeffs)

    for _ in range(10):
        ca = [random.randrange(Q) for _ in range(N)]
        cb = [random.randrange(Q) for _ in range(N)]
        mine = base_mul(ntt(ca), ntt(cb))
        theirs = (R(list(ca)).to_ntt() * R(list(cb)).to_ntt()).coeffs
        assert mine == list(theirs), "base_mul mismatch vs kyber-py"

    return True


if __name__ == "__main__":
    print("zeta^128 mod q          =", pow(ZETA, 128, Q), "(expect 3328 = -1)")
    print("R mod q                 =", R_MOD_Q)
    print("QINV (-q^-1 mod 2^16)   =", QINV)
    print("ZETAS[1..4]             =", ZETAS[1:5])
    print("GAMMAS[0..3]            =", GAMMAS[0:4])
    print()
    print("self-check              :", "PASS" if _selfcheck() else "FAIL")
    print("cross-check vs kyber-py :", "PASS" if _check_against_kyber_py() else "FAIL")
