#!/usr/bin/env python3
"""Retroteca's interface sounds, synthesised from sine waves and noise (original, no samples).
Writes app/Resources/Sounds/*.wav (44.1 kHz, 16-bit mono). Run again after changing a recipe."""
import math, os, random, struct, wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "app", "Resources", "Sounds")

def tone(freq, length, attack=0.004, decay=12.0, harmonics=((1, 1.0),), glide=0.0):
    """A plucked tone: quick attack, exponential decay; `glide` bends the pitch by that ratio over the length."""
    n = int(RATE * length)
    out, phase = [], [0.0] * len(harmonics)
    for i in range(n):
        t = i / RATE
        f = freq * (1 + glide * t / length)
        env = min(1.0, t / attack) * math.exp(-decay * t)
        s = 0.0
        for k, (mult, amp) in enumerate(harmonics):
            phase[k] += 2 * math.pi * f * mult / RATE
            s += amp * math.sin(phase[k])
        out.append(s * env)
    return out

def noise(length, decay=40.0, smooth=0.85):
    random.seed(7)
    out, prev = [], 0.0
    for i in range(int(RATE * length)):
        t = i / RATE
        prev = smooth * prev + (1 - smooth) * random.uniform(-1, 1)
        out.append(prev * math.exp(-decay * t))
    return out

def mix(*parts):
    """(offset seconds, samples, gain) layered into one sound."""
    total = max(int(off * RATE) + len(s) for off, s, _ in parts)
    buf = [0.0] * total
    for off, s, g in parts:
        start = int(off * RATE)
        for i, v in enumerate(s):
            buf[start + i] += v * g
    return buf

def write(name, samples, peak=0.5):
    top = max(abs(v) for v in samples) or 1.0
    fade = int(RATE * 0.004)
    data = bytearray()
    for i, v in enumerate(samples):
        if i >= len(samples) - fade:
            v *= (len(samples) - i) / fade
        data += struct.pack("<h", int(v / top * peak * 32767))
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(bytes(data))

soft = ((1, 1.0), (2, 0.25), (3, 0.08))
os.makedirs(OUT, exist_ok=True)
# Moving between tiles: a short, soft wooden tick.
write("move", mix((0, tone(1650, 0.045, decay=90, harmonics=soft), 1.0), (0, noise(0.012, decay=300), 0.15)), peak=0.28)
# Confirming: two rising notes, a fifth apart.
write("select", mix((0, tone(880, 0.09, decay=35, harmonics=soft), 1.0), (0.045, tone(1318.5, 0.12, decay=30, harmonics=soft), 0.9)), peak=0.35)
# Going back: the same two notes, falling.
write("back", mix((0, tone(1174.7, 0.08, decay=40, harmonics=soft), 0.9), (0.04, tone(784, 0.11, decay=32, harmonics=soft), 1.0)), peak=0.32)
# Changing page (L / R): a short airy swish.
write("page", mix((0, noise(0.09, decay=35, smooth=0.6), 1.0), (0, tone(2200, 0.05, decay=70, glide=-0.3), 0.25)), peak=0.22)
# Starting a game: a bright rising arpeggio.
write("launch", mix((0, tone(523.25, 0.3, decay=9, harmonics=soft), 0.8), (0.07, tone(659.25, 0.3, decay=9, harmonics=soft), 0.8),
                    (0.14, tone(783.99, 0.35, decay=8, harmonics=soft), 0.8), (0.21, tone(1046.5, 0.45, decay=6, harmonics=soft), 0.9)), peak=0.38)
# Something that cannot be done: a low double knock.
write("blocked", mix((0, tone(196, 0.07, decay=45, harmonics=soft), 1.0), (0.09, tone(196, 0.07, decay=45, harmonics=soft), 0.8)), peak=0.35)
print("sounds written to", os.path.normpath(OUT))
