#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare the sound test (tests/sound.asm) recorded by MAME and the simulator.

The test plays four segments of equal length with equal pauses, with the
same CPU timing in MAME and in the simulator. The first two segments (plain
tones) are found as runs of sound between silences; their starts and the
first one's length give the positions of all four. (Detecting the later
ones from silence doesn't work: the envelope gets very quiet at its low
point.) Measured per segment: length, pitch (from zero crossings
around the segment's mean), loudness relative to the first segment (RMS),
and, for the envelope segment, the envelope's repetition rate. The
recordings can have different sample rates and levels.

Passes when the segment spacing agrees within 1 %, and pitches and the
envelope rate within 2 % (the noise's zero-crossing rate within 15 %).
Loudness is only reported: MAME models the AY's output resistors and mixes
the three channels through them, while ym2149.sv uses a fixed volume table
and adds the channels, so levels differ by up to about 40 %.

Usage: compare_sound.py <mame.wav> <sim.wav>
"""
import struct
import sys
import wave


def read_wav(path):
    with wave.open(path, "rb") as w:
        rate, ch, width, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    if width != 2:
        sys.exit(f"{path}: only 16-bit WAV files are supported")
    s = struct.unpack(f"<{n * ch}h", raw)
    return rate, [sum(s[i * ch:(i + 1) * ch]) / ch for i in range(n)]


def segments(rate, s):
    """Runs where the signal moves, separated by at least 20 ms of stillness"""
    win = rate // 1000                      # 1 ms windows
    active = []
    for i in range(0, len(s) - win, win):
        w = s[i:i + win]
        active.append(max(w) - min(w) > 200)
    segs, start, quiet = [], None, 0
    for k, a in enumerate(active):
        if a:
            if start is None:
                start = k
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet >= 20:
                segs.append((start * win, (k - quiet + 1) * win))
                start, quiet = None, 0
    if start is not None:
        segs.append((start * win, len(active) * win))
    return [(a, b) for a, b in segs if b - a > rate // 20]   # ignore clicks


def measure(rate, s, envelope):
    mean = sum(s) / len(s)
    d = [v - mean for v in s]
    rms = (sum(v * v for v in d) / len(d)) ** 0.5
    # pitch: zero crossings around each 10 ms window's own mean, counting only
    # windows with at least a quarter of the segment's peak-to-peak level
    # (the envelope segment fades to nothing)
    pw = rate // 100
    p2p = max(s) - min(s)
    crossings, counted = 0, 0
    for i in range(0, len(s) - pw, pw):
        w = s[i:i + pw]
        if max(w) - min(w) < p2p / 4:
            continue
        m = sum(w) / pw
        crossings += sum(1 for a, b in zip(w, w[1:]) if a < m <= b)
        counted += pw
    freq = crossings * rate / counted if counted else 0
    if not envelope:
        return {"len": len(s) / rate, "freq": freq, "rms": rms, "env": 0}
    # envelope: RMS in 2 ms windows, then the strongest repetition period
    win = max(1, rate // 500)
    env = [(sum(v * v for v in d[i:i + win]) / win) ** 0.5 for i in range(0, len(d) - win, win)]
    em = sum(env) / len(env)
    e = [v - em for v in env]
    best, best_lag = 0, 0
    for lag in range(10, len(e) // 2):      # 20 ms .. half the segment
        c = sum(a * b for a, b in zip(e, e[lag:])) / (len(e) - lag)
        if c > best:
            best, best_lag = c, lag
    env_rate = 500 / best_lag if best_lag and best > 0.3 * (sum(v * v for v in e) / len(e)) else 0
    return {"len": len(s) / rate, "freq": freq, "rms": rms, "env": env_rate}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    res, spacing = [], []
    for path in sys.argv[1:]:
        rate, s = read_wav(path)
        found = segments(rate, s)
        if len(found) < 2:
            sys.exit(f"{path}: can't find the first two sound segments")
        (a0, b0), (a1, _) = found[0], found[1]
        period, length, margin = a1 - a0, b0 - a0, rate // 200
        spacing.append(period / rate)
        res.append([measure(rate, s[a0 + k * period + margin:a0 + k * period + length - margin], k == 2)
                    for k in range(4)])
    mame, sim = res
    print(f"segment spacing: MAME {spacing[0]:.4f} s, simulator {spacing[1]:.4f} s")
    ok = abs(spacing[1] / spacing[0] - 1) < 0.01
    names = ["A 440 Hz", "B 880 Hz", "C envelope", "A noise"]
    for i, (m, s) in enumerate(zip(mame, sim)):
        name = names[i] if i < len(names) else f"segment {i + 1}"
        rel_m, rel_s = m["rms"] / mame[0]["rms"], s["rms"] / sim[0]["rms"]
        ftol = 0.15 if "noise" in name else 0.02
        checks = [
            abs(s["len"] / m["len"] - 1) < 0.02,
            abs(s["freq"] / m["freq"] - 1) < ftol,
            (m["env"] == 0 and s["env"] == 0) or (m["env"] and s["env"] and abs(s["env"] / m["env"] - 1) < 0.02),
        ]
        print(f"{name:12s} length {m['len']:.3f}/{s['len']:.3f} s  pitch {m['freq']:7.1f}/{s['freq']:7.1f} Hz  "
              f"loudness {rel_m:.2f}/{rel_s:.2f}  envelope {m['env']:.2f}/{s['env']:.2f} Hz  "
              f"{'ok' if all(checks) else 'DIFFERENT'}")
        ok = ok and all(checks)
    print("(each pair is MAME/simulator)")
    if not ok:
        sys.exit(1)
    print("Sound matches MAME.")


if __name__ == "__main__":
    main()
