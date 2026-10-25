#!/usr/local/bin/python3
"""Render the saber sounds into ASTROSPIKE/Sounds as 44.1 kHz mono WAV.

    /usr/local/bin/python3 scripts/saber_sounds.py

Everything is synthesised here: a buzzing hum built from whole harmonics,
a pitch sweep for the ignite and retract, a doppler bend plus a swept
noise band for the swoosh, and a metallic crack with crackle for the clash.
The hum loops: every partial and the wobble repeat a whole number of times in
its two seconds, and its noise is built periodic, so the seam is invisible.
"""
import os
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "ASTROSPIKE", "Sounds")
rng = np.random.default_rng(1977)


def t_of(seconds):
    return np.arange(int(RATE * seconds)) / RATE


def buzz(phase, harmonics=24, tilt=1.1):
    """A bright, slightly nasal tone: harmonics falling as 1/n^tilt, odd ones a
    touch louder, so it sits between a saw and a square."""
    out = np.zeros_like(phase)
    for n in range(1, harmonics + 1):
        weight = (1.25 if n % 2 else 0.8) / n ** tilt
        out += weight * np.sin(n * phase)
    return out


def band(signal, low, high, order=2):
    sos = butter(order, [low, high], btype="band", fs=RATE, output="sos")
    return sosfilt(sos, signal)


def highpass(signal, cutoff, order=2):
    return sosfilt(butter(order, cutoff, btype="high", fs=RATE, output="sos"), signal)


def lowpass(signal, cutoff, order=2):
    return sosfilt(butter(order, cutoff, btype="low", fs=RATE, output="sos"), signal)


def fades(signal, in_ms=4, out_ms=5):
    a, b = int(RATE * in_ms / 1000), int(RATE * out_ms / 1000)
    signal = signal.copy()
    if a: signal[:a] *= np.linspace(0, 1, a)
    if b: signal[-b:] *= np.linspace(1, 0, b)
    return signal


def normalise(signal, peak):
    return signal * (peak / np.max(np.abs(signal)))


def write(name, signal):
    data = np.clip(signal, -1, 1)
    wavfile.write(os.path.join(OUT, name + ".wav"), RATE, (data * 32767).astype(np.int16))
    print(f"{name}: {len(data) / RATE:.2f}s peak {np.max(np.abs(data)):.2f}")


HUM_HZ = 92.0


def hum_tone(phase, wobble):
    """The blade's voice for a given phase track: the buzz, soft-clipped so it
    growls, over a pure sub an octave down."""
    tone = np.tanh(1.6 * buzz(phase)) + 0.5 * np.sin(phase / 2)
    return tone * wobble


def hum():
    # 2 s: 92 and 92.5 Hz both land whole cycles, so they beat at 0.5 Hz and the
    # wobble (3 Hz, 6 cycles) and noise all close the loop exactly.
    seconds = 2.0
    t = t_of(seconds)
    wobble = 1 + 0.08 * np.sin(2 * np.pi * 3 * t)
    main = hum_tone(2 * np.pi * HUM_HZ * t, wobble)
    beat = hum_tone(2 * np.pi * (HUM_HZ + 0.5) * t, wobble)
    # Periodic noise: random phases on whole-loop bins, kept to a hiss band.
    n = len(t)
    spectrum = np.zeros(n // 2 + 1, complex)
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    keep = (freqs > 1800) & (freqs < 6000)
    spectrum[keep] = np.exp(2j * np.pi * rng.random(keep.sum()))
    hiss = np.fft.irfft(spectrum, n)
    hiss /= np.max(np.abs(hiss))
    signal = 0.62 * main + 0.38 * beat + 0.05 * hiss
    return normalise(signal, 0.6)


def sweep_phase(freq):
    return 2 * np.pi * np.cumsum(freq) / RATE


def ignite():
    # A snap of hiss, then the hum shooting up from a low growl to pitch and
    # overshooting a hair before it settles, the level swelling to full.
    seconds = 0.55
    t = t_of(seconds)
    u = t / seconds
    freq = HUM_HZ * (0.35 + 0.75 * (1 - np.exp(-u * 9)) - 0.1 * np.clip(u - 0.4, 0, 1))
    tone = hum_tone(sweep_phase(freq), 1)
    tone = lowpass(tone, 600) * (1 - np.exp(-u * 30)) + 0.0
    bright = highpass(tone, 300) * np.exp(-u * 3)
    snap = highpass(rng.standard_normal(len(t)), 2500) * np.exp(-t / 0.05)
    crack = band(rng.standard_normal(len(t)), 400, 2200) * np.exp(-t / 0.018)
    level = np.minimum(1, u * 6) * (1 - 0.35 * u)
    signal = (tone + 0.6 * bright) * level + 0.35 * snap + 0.5 * crack
    return fades(normalise(signal, 0.85), 2, 30)


def retract():
    # The hum sucked back in: pitch falling away, level closing, a soft
    # breath of hiss underneath.
    seconds = 0.42
    t = t_of(seconds)
    u = t / seconds
    freq = HUM_HZ * (1.05 - 0.75 * u ** 0.7)
    tone = hum_tone(sweep_phase(freq), 1)
    # Darkening as it goes: a bright copy handing over to a dull one.
    tone = lowpass(tone, 2400) * (1 - u) + lowpass(tone, 500) * u
    level = (1 - u) ** 1.6 * np.minimum(1, u * 40)
    breath = band(rng.standard_normal(len(t)), 1500, 5000) * (1 - u) ** 2 * 0.15
    signal = tone * level + breath
    return fades(normalise(signal, 0.7), 2, 20)


def swoosh():
    # A blade swung past the ear: the hum doppler-bends up then down, loudest
    # in the middle, under a band of air whose centre sweeps with it.
    seconds = 0.32
    t = t_of(seconds)
    u = t / seconds
    bell = np.exp(-((u - 0.45) / 0.2) ** 2)
    freq = HUM_HZ * (1 + 0.55 * bell - 0.15 * u)
    tone = hum_tone(sweep_phase(freq), 1)
    air = np.zeros(len(t))
    noise = rng.standard_normal(len(t))
    chunk = 512
    for start in range(0, len(t), chunk):
        mid = start / len(t)
        centre = 600 + 2600 * np.exp(-((mid - 0.45) / 0.22) ** 2)
        piece = band(noise[max(0, start - 2048):start + chunk], centre * 0.6, centre * 1.6)
        air[start:start + chunk] = piece[-len(air[start:start + chunk]):]
    signal = tone * bell * 0.8 + air * bell * 0.9
    return fades(normalise(signal, 0.8), 3, 10)


def clash():
    # Blade on ball: a hard crack, a ring of inharmonic metal, and a scatter
    # of crackle sparks over a burst of distorted hum.
    seconds = 0.45
    t = t_of(seconds)
    crack = highpass(rng.standard_normal(len(t)), 1200) * np.exp(-t / 0.012)
    ring = sum(
        a * np.sin(2 * np.pi * f * t + rng.random() * 6.28) * np.exp(-t / d)
        for f, a, d in [(1180, 0.5, 0.09), (1873, 0.4, 0.07), (2641, 0.35, 0.05), (3395, 0.25, 0.04), (4720, 0.2, 0.03)]
    )
    sparks = np.zeros(len(t))
    for _ in range(70):
        at = int(abs(rng.normal(0, 0.09)) * RATE)
        if at < len(t):
            sparks[at] += rng.choice([-1, 1]) * rng.uniform(0.3, 1)
    sparks = highpass(sparks, 2000) * np.exp(-t / 0.15)
    burst = np.tanh(3 * hum_tone(2 * np.pi * HUM_HZ * 1.3 * t, 1)) * np.exp(-t / 0.08)
    signal = 0.9 * crack + 0.6 * ring + 1.4 * sparks + 0.45 * burst
    return fades(normalise(signal, 0.95), 0.5, 20)


if __name__ == "__main__":
    write("saberHum", hum())
    write("saberIgnite", ignite())
    write("saberRetract", retract())
    write("saberSwoosh", swoosh())
    write("saberClash", clash())
