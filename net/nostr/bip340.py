#!/usr/bin/env python3
"""
bip340.py — minimal BIP340 Schnorr signatures over secp256k1 (pure stdlib).
Reference-quality implementation of the BIP340 spec (no external deps).

Used by AgentoNet for real Nostr interop (NIP-01 requires secp256k1 Schnorr).
"""

import hashlib

# ── curve parameters ──────────────────────────────────────────────────────────
p  = 2**256 - 2**32 - 977
n  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
G  = (Gx, Gy)

# ── field/point helpers (affine, None = infinity) ────────────────────────────
def point_add(P1, P2):
    if P1 is None: return P2
    if P2 is None: return P1
    if P1[0] == P2[0]:
        if (P1[1] + P2[1]) % p == 0:
            return None
        lam = (3 * P1[0] * P1[0]) * pow(2 * P1[1], p - 2, p) % p
    else:
        lam = (P2[1] - P1[1]) * pow(P2[0] - P1[0], p - 2, p) % p
    x3 = (lam * lam - P1[0] - P2[0]) % p
    return (x3, (lam * (P1[0] - x3) - P1[1]) % p)

def point_mul(s, P):
    r = None
    while s > 0:
        if s & 1:
            r = point_add(r, P)
        P = point_add(P, P)
        s >>= 1
    return r

def bytes_from_int(x):
    return x.to_bytes(32, "big")

def bytes_from_point(P):
    return bytes_from_int(P[0])

def int_from_bytes(b):
    return int.from_bytes(b, "big")

def point_negate(P):
    return None if P is None else (P[0], (-P[1]) % p)

def lift_x(b):
    x = int_from_bytes(b)
    if not (0 <= x < p):
        return None
    y_sq = (pow(x, 3, p) + 7) % p
    y = pow(y_sq, (p + 1) // 4, p)
    if pow(y, 2, p) != y_sq:
        return None
    return (x, y if y % 2 == 0 else p - y)

def sha256(*data):
    h = hashlib.sha256()
    for d in data:
        h.update(d)
    return h.digest()

def tagged_hash(tag, msg):
    t = sha256(tag.encode())
    return sha256(t, t, msg)

# ── public API ────────────────────────────────────────────────────────────────
def pubkey_gen(seckey: bytes) -> bytes:
    """Return 32-byte x-only public key."""
    d = int_from_bytes(seckey)
    if not (1 <= d < n):
        raise ValueError("secret key out of range")
    P = point_mul(d, G)
    if P is None:
        raise ValueError("invalid public key")
    return bytes_from_point(P)

def schnorr_sign(msg: bytes, seckey: bytes, aux_rand: bytes) -> bytes:
    """Return 64-byte Schnorr signature (BIP340)."""
    if len(msg) != 32:
        raise ValueError("msg must be the 32-byte event id")
    if len(aux_rand) != 32:
        raise ValueError("aux_rand must be 32 bytes")
    d = int_from_bytes(seckey)
    if not (1 <= d < n):
        raise ValueError("secret key out of range")
    P = point_mul(d, G)
    if P is None:
        raise ValueError("invalid public key")
    d = d if P[1] % 2 == 0 else n - d
    t = d ^ int_from_bytes(tagged_hash("BIP0340/aux", aux_rand))
    k0 = int_from_bytes(tagged_hash("BIP0340/nonce",
                        bytes_from_int(t) + bytes_from_point(P) + msg)) % n
    if k0 == 0:
        raise RuntimeError("nonce generation failed")
    R = point_mul(k0, G)
    k = k0 if R[1] % 2 == 0 else n - k0
    e = int_from_bytes(tagged_hash("BIP0340/challenge",
                       bytes_from_point(R) + bytes_from_point(P) + msg)) % n
    sig = bytes_from_point(R) + bytes_from_int((k + e * d) % n)
    if not schnorr_verify(msg, bytes_from_point(P), sig):
        raise RuntimeError("self-verification failed")
    return sig

def schnorr_verify(msg: bytes, pubkey: bytes, sig: bytes) -> bool:
    """Verify a 64-byte Schnorr signature for a 32-byte x-only pubkey."""
    if len(pubkey) != 32 or len(sig) != 64 or len(msg) != 32:
        return False
    P = lift_x(pubkey)
    if P is None:
        return False
    r = int_from_bytes(sig[:32])
    s = int_from_bytes(sig[32:])
    if r >= p or s >= n:
        return False
    e = int_from_bytes(tagged_hash("BIP0340/challenge", sig[:32] + pubkey + msg)) % n
    R = point_add(point_mul(s, G), point_mul(n - e, P))
    if R is None or R[1] % 2 != 0 or R[0] != r:
        return False
    return True

# ── CLI self-test ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import os, sys
    sk = os.urandom(32)
    pk = pubkey_gen(sk)
    msg = sha256(b"agentic-os nostr test")
    aux = os.urandom(32)
    sig = schnorr_sign(msg, sk, aux)
    ok  = schnorr_verify(msg, pk, sig)
    bad = schnorr_verify(sha256(b"tampered"), pk, sig)
    print("pub:", pk.hex())
    print("sig:", sig.hex()[:32] + "…")
    print("verify good:", ok, "| tampered:", bad)
    sys.exit(0 if (ok and not bad) else 1)
