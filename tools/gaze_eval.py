#!/usr/bin/env python3
"""Replay captured gaze sessions through candidate classifiers and score them.

Shiftly writes a labelled CSV every time you calibrate, to
~/Library/Logs/Shiftly-gaze/. Each row is one camera frame plus the display and
point that was on screen when it was captured, which makes picking a classifier
a scoring problem instead of an opinion.

    tools/gaze_eval.py                     # every capture, leave-one-out
    tools/gaze_eval.py a.csv b.csv         # train on a, test on b
    tools/gaze_eval.py --margin 0.8

Reported per metric:

  acc       fraction of frames put on the right display, ignoring abstentions
  decided   fraction of frames confident enough to act on at all
  wrong     fraction of ALL frames sent to the wrong display, which is the one
            that actually costs you something: an abstention leaves focus alone,
            a wrong answer moves the wrong window
  lag       frames from a change of target until the answer follows it, which is
            the latency the margin and any smoothing buy or cost
"""

import argparse
import csv
import glob
import math
import os
import statistics as st
import sys

AXES = ["headX", "headY", "eyeX", "eyeY"]
CAPTURES = os.path.expanduser("~/Library/Logs/Shiftly-gaze")
FLOOR = 0.02


def load(path):
    """Rows as dicts, skipping the '#' preamble."""
    with open(path) as handle:
        lines = [line for line in handle if not line.startswith("#")]
    rows = []
    for row in csv.DictReader(lines):
        rows.append(
            {
                "t": float(row["t"]),
                "display": int(row["display"]),
                "point": (float(row["targetX"]), float(row["targetY"])),
                "style": row.get("style", "?"),
                "x": [float(row[a]) for a in AXES],
            }
        )
    if not rows:
        raise SystemExit(f"{path}: no frames")
    return rows


def bursts(rows):
    """Split a capture back into one group per calibration dot."""
    out, current = [], [rows[0]]
    for row in rows[1:]:
        same = (row["display"] == current[-1]["display"]
                and row["point"] == current[-1]["point"]
                and row["style"] == current[-1]["style"])
        # A gap means the dot moved even if it landed on the same coordinates.
        if same and row["t"] - current[-1]["t"] < 0.5:
            current.append(row)
        else:
            out.append(current)
            current = [row]
    out.append(current)
    return out


def spread(values):
    return st.stdev(values) if len(values) > 1 else 0.0


def train(rows):
    """One reference per burst, plus the two candidate axis scalings."""
    groups = bursts(rows)
    refs = [
        {
            "display": g[0]["display"],
            "x": [st.mean(r["x"][i] for r in g) for i in range(4)],
        }
        for g in groups
    ]

    # How much an axis wobbles while a single dot is held: measurement noise.
    jitter = [st.median([spread([r["x"][i] for r in g]) for g in groups]) for i in range(4)]

    per_display = {}
    for ref in refs:
        per_display.setdefault(ref["display"], []).append(ref["x"])

    between, within = [], []
    for i in range(4):
        means = [st.mean(v[i] for v in vs) for vs in per_display.values()]
        between.append(spread(means))
        within.append(st.mean([spread([v[i] for v in vs]) for vs in per_display.values()]))

    def norm(w):
        peak = max(w) or 1.0
        return [v / peak for v in w]

    return {
        "refs": refs,
        # What shipped first: scaled by how much an axis varies across one
        # display's dots, which counts "tracking where on the screen you look"
        # as noise and buries the pupil terms.
        "spread": norm([between[i] / max(within[i], FLOOR) for i in range(4)]),
        # Scaled by per-frame jitter instead.
        "jitter": norm([between[i] / max(jitter[i], FLOOR) for i in range(4)]),
        "equal": [1.0, 1.0, 1.0, 1.0],
        "eyes_only": [0.0, 0.0, 1.0, 1.0],
        "head_only": [1.0, 1.0, 0.0, 0.0],
    }


def classify(model, weights, x, margin, centroid=False):
    """Nearest reference (or nearest per-display mean), or None if too close."""
    best = {}
    if centroid:
        groups = {}
        for ref in model["refs"]:
            groups.setdefault(ref["display"], []).append(ref["x"])
        pool = [
            {"display": d, "x": [st.mean(v[i] for v in vs) for i in range(4)]}
            for d, vs in groups.items()
        ]
    else:
        pool = model["refs"]

    for ref in pool:
        d = math.sqrt(sum(((x[i] - ref["x"][i]) * weights[i]) ** 2 for i in range(4)))
        key = ref["display"]
        if key not in best or d < best[key]:
            best[key] = d

    ranked = sorted(best.items(), key=lambda kv: kv[1])
    if len(ranked) < 2:
        return ranked[0][0] if ranked else None
    return ranked[0][0] if ranked[0][1] <= ranked[1][1] * margin else None


def median_of(window):
    return [st.median([w[i] for w in window]) for i in range(4)]


def score(model, weights, rows, margin, frames, centroid):
    hits = misses = abstain = 0
    window = []
    lags, pending, since = [], None, 0

    for row in rows:
        window.append(row["x"])
        window = window[-frames:]
        guess = classify(model, weights, median_of(window), margin, centroid)

        if guess is None:
            abstain += 1
        elif guess == row["display"]:
            hits += 1
        else:
            misses += 1

        # Latency: how many frames after the dot moves before the answer agrees.
        if row["display"] != pending:
            if pending is not None and since is not None:
                lags.append(None)  # never caught up before the next move
            pending, since = row["display"], 0
        elif since is not None:
            since += 1
            if guess == row["display"]:
                lags.append(since)
                since = None

    total = hits + misses + abstain
    caught = [v for v in lags if v is not None]
    return {
        "acc": hits / max(hits + misses, 1),
        "decided": (hits + misses) / max(total, 1),
        "wrong": misses / max(total, 1),
        "lag": st.median(caught) if caught else float("nan"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="*")
    parser.add_argument("--margin", type=float, default=0.85)
    parser.add_argument("--frames", type=int, default=3)
    args = parser.parse_args()

    files = args.files or sorted(glob.glob(os.path.join(CAPTURES, "*.csv")))
    if not files:
        raise SystemExit(f"no captures in {CAPTURES} — calibrate once to record one")

    # Two or more files: train on all but the last, test on the last, so the
    # score says whether a metric generalises rather than whether it memorised.
    if len(files) > 1:
        train_rows = [r for f in files[:-1] for r in load(f)]
        test_rows = load(files[-1])
        print(f"train: {', '.join(os.path.basename(f) for f in files[:-1])}")
        print(f"test:  {os.path.basename(files[-1])}\n")
    else:
        train_rows = test_rows = load(files[0])
        print(f"{os.path.basename(files[0])} (train == test, scores are optimistic)\n")

    model = train(train_rows)
    print(f"margin {args.margin}  median-of-{args.frames} frames  {len(test_rows)} test frames\n")
    print(f"{'metric':<15} {'weights (headX/headY/eyeX/eyeY)':<31} "
          f"{'acc':>6} {'decided':>8} {'wrong':>7} {'lag':>5}")

    for name in ["spread", "jitter", "equal", "eyes_only", "head_only"]:
        weights = model[name]
        for centroid in (False, True):
            result = score(model, weights, test_rows, args.margin, args.frames, centroid)
            label = f"{name}{'+cent' if centroid else ''}"
            shown = "/".join(f"{w:.2f}" for w in weights)
            print(f"{label:<15} {shown:<31} {result['acc']:>6.1%} "
                  f"{result['decided']:>8.1%} {result['wrong']:>7.1%} {result['lag']:>5.0f}")

    # Both usage styles have to work off one profile, and a single-style
    # calibration scores well on its own style while failing the other, so an
    # overall number can hide the failure entirely. Split them out.
    styles = sorted({r["style"] for r in test_rows} - {"?"})
    if len(styles) > 1:
        print("\nby style, jitter-weighted nearest reading:")
        for style in styles:
            subset = [r for r in test_rows if r["style"] == style]
            result = score(model, model["jitter"], subset, args.margin, args.frames, False)
            print(f"  {style:<8} {len(subset):>4} frames   acc {result['acc']:>6.1%}   "
                  f"wrong {result['wrong']:>6.1%}   lag {result['lag']:>3.0f}")


if __name__ == "__main__":
    sys.exit(main())
