"""
EXERCISE -- implement the forward NTT yourself from FIPS 203 Algorithm 9.


Do not open ntt_ref.py until this passes. It is ~15 lines.




Run:  python3 exercise_ntt.py
"""

Q = 3329
N = 256
ZETA = 17


def brv7(i):
    """Reverse the low 7 bits of i."""
    return int(f"{i:07b}"[::-1], 2)


# ZETAS[k] is consumed sequentially, k = 1, 2, 3, ... as you walk the layers.
ZETAS = [pow(ZETA, brv7(i), Q) for i in range(128)]


def my_ntt(f):
    """
    FIPS 203 Algorithm 9.

    Pseudocode:
        k = 1
        for len in [128, 64, 32, 16, 8, 4, 2]:          # 7 layers
            for start in range(0, 256, 2*len):
                z = ZETAS[k]; k += 1
                for j in range(start, start + len):
                    t        = z * f[j+len]   mod q     # Cooley-Tukey
                    f[j+len] = f[j] - t       mod q
                    f[j]     = f[j] + t       mod q
        return f
    """
    f = list(f)
    
    k = 1
    for length in [128, 64, 32, 16, 8, 4, 2]:
        for start in range(0, N, 2 * length):
            z = ZETAS[k]
            k += 1
            for j in range(start, start + length):
                # 1. Compute t first using the original f[j+length]
                t = (z * f[j + length]) % Q
                
                # 2. Update f[j+length] using the ORIGINAL f[j] and the new t
                f[j + length] = (f[j] - t) % Q
                
                # 3. Finally, update f[j] 
                f[j] = (f[j] + t) % Q
                
    return f


def check():
    import random
    random.seed(42)

    # Sanity on the constants themselves.
    assert pow(ZETA, 256, Q) == 1, "zeta must be a 256th root of unity"
    assert pow(ZETA, 128, Q) == Q - 1, "zeta^128 must be -1 (negacyclic)"
    assert 3328 == 2**8 * 13, "3328 = 2^8 * 13 -- why there is no 512th root"

    # A known-answer check: the all-ones polynomial.
    ones = my_ntt([1] * N)

    # Independent check against kyber-py.
    from kyber_py.polynomials.polynomials import PolynomialRing
    R = PolynomialRing()
    assert list(R.ntt_zetas) == ZETAS, "zeta table mismatch"
    assert list(R([1] * N).to_ntt().coeffs) == ones, "all-ones case wrong"

    for _ in range(50):
        c = [random.randrange(Q) for _ in range(N)]
        assert my_ntt(c) == list(R(list(c)).to_ntt().coeffs), "mismatch"

    print("PASS -- your NTT matches kyber-py on 50 random polynomials.")
    print("       You now understand the dataflow. Open ntt_ref.py.")


if __name__ == "__main__":
    check()
