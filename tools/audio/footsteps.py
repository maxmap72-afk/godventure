"""Synthesized footstep sounds for the rooms' floors (AdvRoom.footsteps).

Usage: python3 tools/audio/footsteps.py OUT_DIR
Writes passi_<floor>_<n>.wav (terra, pietra, legno, tappeto; 4 variants each): a short
heel-and-sole impact shaped from filtered noise and a low thump, slightly different each time."""
import sys, os, wave
import numpy as np

SR = 22050


def lowpass(x, cut):
    a = np.exp(-2 * np.pi * cut / SR)
    y = np.zeros_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def highpass(x, cut):
    return x - lowpass(x, cut)


def env(n, attack, decay):
    t = np.arange(n) / SR
    e = np.minimum(t / attack, 1.0) * np.exp(-np.maximum(t - attack, 0) / decay)
    return e


def thump(n, freq, decay, rng):
    t = np.arange(n) / SR
    f = freq * (1 + 0.6 * np.exp(-t / 0.01)) * rng.uniform(0.92, 1.08)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / decay)


def step(kind, rng):
    n = int(SR * 0.28)
    noise = rng.standard_normal(n)
    if kind == "terra":        # packed earth, grit and a few dry leaves
        body = lowpass(noise, 900) * env(n, 0.004, 0.045) * 2.2
        grit = highpass(noise, 2500) * env(n, 0.002, 0.02) * 0.35
        crackle = np.zeros(n)
        for _ in range(rng.integers(3, 7)):
            p = rng.integers(int(0.01 * SR), int(0.09 * SR))
            m = min(int(0.004 * SR), n - p)
            crackle[p:p + m] += highpass(rng.standard_normal(m), 3000) * rng.uniform(0.2, 0.5)
        s = body + grit + crackle + thump(n, 70, 0.03, rng) * 0.5
    elif kind == "pietra":     # hard heel on stone, short and bright
        click = highpass(noise, 2000) * env(n, 0.0008, 0.012) * 0.9
        knock = thump(n, 160, 0.025, rng) * 0.7
        scuff = lowpass(highpass(noise, 600), 4000) * env(n, 0.01, 0.04) * 0.25
        s = click + knock + scuff
    elif kind == "legno":      # boards: hollow knock with a short ring
        knock = lowpass(noise, 1500) * env(n, 0.002, 0.02) * 0.9
        ring = thump(n, rng.uniform(190, 260), 0.07, rng) * 0.6 + thump(n, 420, 0.03, rng) * 0.2
        s = knock + ring
    else:                      # carpet: muffled
        s = lowpass(noise, 450) * env(n, 0.006, 0.05) * 2.5 + thump(n, 80, 0.03, rng) * 0.4
    s = s / (np.abs(s).max() + 1e-9) * 0.3
    tail = np.nonzero(np.abs(s) > 0.003)[0]
    return s[: tail[-1] + 1 if len(tail) else n]


def write(path, s):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(s, -1, 1) * 32767).astype("<i2").tobytes())


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for k, kind in enumerate(["terra", "pietra", "legno", "tappeto"]):
        for v in range(1, 5):
            write(os.path.join(out, "passi_%s_%d.wav" % (kind, v)), step(kind, np.random.default_rng(100 * k + v)))
