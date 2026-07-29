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

AXES = ["headX", "headY", "eyeX", "eyeY", "lidY"]
CAPTURES = os.path.expanduser("~/Library/Logs/Shiftly-gaze")
FLOOR = 0.02

# Index of each axis within a row's "x", for the fits that care which is which.
HEAD_X, HEAD_Y, EYE_X, EYE_Y, LID_Y = range(len(AXES))
HORIZONTAL = [HEAD_X, EYE_X]
VERTICAL = [HEAD_Y, EYE_Y, LID_Y]

def version(path):
    """Capture format from the header. 1 has no lidY and scales eyeY differently."""
    with open(path) as handle:
        for line in handle:
            if not line.startswith("#"):
                return 1
            if "shiftly gaze capture v" in line:
                return int(line.strip().rsplit("v", 1)[1])
    return 1


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
                # A v1 capture has no lidY column and reports eyeY against a
                # different denominator. Zero-filling keeps it loadable for the
                # display-level scores, which don't depend on either.
                "x": [float(row[a]) if a in row else 0.0 for a in AXES],
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
            "x": [st.mean(r["x"][i] for r in g) for i in range(len(AXES))],
        }
        for g in groups
    ]

    # How much an axis wobbles while a single dot is held: measurement noise.
    jitter = [st.median([spread([r["x"][i] for r in g]) for g in groups]) for i in range(len(AXES))]

    per_display = {}
    for ref in refs:
        per_display.setdefault(ref["display"], []).append(ref["x"])

    between, within = [], []
    for i in range(len(AXES)):
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
        "spread": norm([between[i] / max(within[i], FLOOR) for i in range(len(AXES))]),
        # Scaled by per-frame jitter instead.
        "jitter": norm([between[i] / max(jitter[i], FLOOR) for i in range(len(AXES))]),
        "equal": [1.0] * len(AXES),
        "eyes_only": [0.0, 0.0, 1.0, 1.0, 1.0],
        "head_only": [1.0, 1.0, 0.0, 0.0, 0.0],
        # Jitter-scaled but with the eyelid term switched off, which is how we
        # find out whether adding it bought anything or just added a dimension.
        "no_lid": norm([between[i] / max(jitter[i], FLOOR) if i != LID_Y else 0.0
                        for i in range(len(AXES))]),
    }


def classify(model, weights, x, margin, centroid=False):
    """Nearest reference (or nearest per-display mean), or None if too close."""
    best = {}
    if centroid:
        groups = {}
        for ref in model["refs"]:
            groups.setdefault(ref["display"], []).append(ref["x"])
        pool = [
            {"display": d, "x": [st.mean(v[i] for v in vs) for i in range(len(AXES))]}
            for d, vs in groups.items()
        ]
    else:
        pool = model["refs"]

    for ref in pool:
        d = math.sqrt(sum(((x[i] - ref["x"][i]) * weights[i]) ** 2 for i in range(len(AXES))))
        key = ref["display"]
        if key not in best or d < best[key]:
            best[key] = d

    ranked = sorted(best.items(), key=lambda kv: kv[1])
    if len(ranked) < 2:
        return ranked[0][0] if ranked else None
    return ranked[0][0] if ranked[0][1] <= ranked[1][1] * margin else None


def median_of(window):
    return [st.median([w[i] for w in window]) for i in range(len(AXES))]


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


def fit_ls(features, values):
    """Least squares for value ~ c + sum(coefficient * feature), or None if singular.

    Mirrors GazeProfile.solve, including its refusal to fit without headroom
    over the parameter count: a fit with as many parameters as dots passes
    through every one of them and has therefore fitted the jitter.
    """
    terms = len(features[0]) + 1 if features else 0
    if len(features) < terms + 2:
        return None
    design = [[1.0] + list(f) for f in features]
    m = [[sum(r[i] * r[j] for r in design) for j in range(terms)]
         + [sum(r[i] * v for r, v in zip(design, values))] for i in range(terms)]

    for col in range(terms):
        pivot = max(range(col, terms), key=lambda r: abs(m[r][col]))
        if abs(m[pivot][col]) < 1e-9:
            return None
        m[col], m[pivot] = m[pivot], m[col]
        lead = m[col][col]
        m[col] = [v / lead for v in m[col]]
        for r in range(terms):
            if r != col and m[r][col]:
                factor = m[r][col]
                m[r] = [a - factor * b for a, b in zip(m[r], m[col])]
    return [m[i][terms] for i in range(terms)]


def evaluate(term, x):
    """One placement term: an axis, or two multiplied together."""
    first, second = term
    return x[first] if second is None else x[first] * x[second]


def shapes(own, cross, drop=()):
    """Term sets to try for one axis, matching GazeProfile.placement.

    Every axis linearly, then the carrying axes alone as the fallback for a
    calibration too small to support the corrections. Second-order terms were
    measured and rejected; see the note on GazeProfile.terms.
    """
    own = [a for a in own if a not in drop]
    cross = [a for a in cross if a not in drop]
    return [[(a, None) for a in own + cross], [(a, None) for a in own]]


def coverage(rows_):
    return {(r["display"], r["style"]) for r in rows_}


def arrangement(path):
    """Display frames from the capture's '# arrangement=' header, id -> rect."""
    out = {}
    with open(path) as handle:
        for line in handle:
            if not line.startswith("#"):
                break
            if "arrangement=" not in line:
                continue
            for part in line.split("arrangement=", 1)[1].strip().split("|"):
                identifier, rect = part.split(":")
                out[int(identifier)] = tuple(float(v) for v in rect.split(","))
    return out


# The layouts Shiftly can snap to, as (name, columns, rows). Sixths is the
# demanding one: on a 3440x1440 ultrawide its tiles are 1147x720.
LAYOUTS = [("halves", 2, 1), ("thirds", 3, 1), ("quarters", 2, 2), ("sixths", 3, 2)]

# Matches gazeWindowInset in Model.swift: how far inside a window the estimate
# has to land before that window counts as the one you meant.
GAZE_WINDOW_INSET = 80.0


def tile_of(point, rect, cols, rows):
    x, y, w, h = rect
    col = min(int((point[0] - x) / w * cols), cols - 1)
    row = min(int((point[1] - y) / h * rows), rows - 1)
    return max(col, 0), max(row, 0)


def tile_report(plan, predict, frames):
    """Whether the dot would pick the right window slot, from the error spread.

    Scored from the residuals rather than by asking which tile each calibration
    dot fell in. That direct version is contaminated by where the dots happen to
    sit: a 3x3 grid puts a third of them exactly on the boundary of a 2-wide
    layout, where any error at all is a coin flip, and it scored halves below
    thirds as a result. Which says something about the grid, nothing about the
    tracker.

    Two numbers, because "will it pick the right window" depends on where in the
    window you're looking. `centre` is looking at the middle of a slot, the best
    case and roughly what you do with a window you're reading. `anywhere` is a
    target uniformly placed in the slot, which counts looking near its edge as
    the miss it usually is. For a uniform offset the hit rate works out to
    mean(max(0, 1 - |error| / slot)), no sampling needed.
    """
    if not frames:
        return
    residuals = {}
    for fitted, chunk in plan:
        for row in chunk:
            predicted = predict(fitted, row["display"], row["x"])
            if predicted is None:
                continue
            residuals.setdefault(row["display"], ([], []))
            residuals[row["display"]][0].append(predicted[0] - row["point"][0])
            residuals[row["display"]][1].append(predicted[1] - row["point"][1])
    if not residuals:
        return

    def centre(errors, size):
        return sum(abs(e) < size / 2 for e in errors) / len(errors)

    def simulate(ex, ey, full_w, full_h, cols, rows_, steps=28):
        """Run the shipped rule over targets placed all over the display.

        The app only acts when the estimate lands properly inside a window, so a
        near-miss abstains instead of guessing. That makes three outcomes, not
        two, and only one of them costs anything: doing nothing leaves the
        gesture on the window you already had, while acting on the wrong window
        moves something you didn't mean to move.

        Targets span the whole display rather than one slot, so that an estimate
        drifting off the outside edge counts as nothing to act on, which is what
        it is. Scoring it against a slot in isolation invents a neighbouring
        window past the edge of the screen and blames the tracker for picking it.
        """
        w, h = full_w / cols, full_h / rows_

        def landed(position, size, count):
            index = math.floor(position / size)
            if index < 0 or index >= count:
                return None
            offset = position - index * size
            edge = min(GAZE_WINDOW_INSET, size * 0.2)
            return index if edge <= offset <= size - edge else None

        right = wrong = total = 0
        for dx, dy in zip(ex, ey):
            for i in range(steps):
                true_x = (i + 0.5) / steps * full_w
                got_x = landed(true_x + dx, w, cols)
                want_x = min(int(true_x / w), cols - 1)
                for j in range(steps):
                    true_y = (j + 0.5) / steps * full_h
                    total += 1
                    if got_x is None:
                        continue
                    got_y = landed(true_y + dy, h, rows_)
                    if got_y is None:
                        continue
                    if got_x == want_x and got_y == min(int(true_y / h), rows_ - 1):
                        right += 1
                    else:
                        wrong += 1
        return right / total, wrong / total

    print("\nwindow slot outcomes, from the held-out error spread")
    print(f"{'layout':<10} {'display':>8} {'slot px':>12} {'centre':>8}"
          f"   {'acts right':>10} {'acts wrong':>10} {'does nothing':>13}")
    for name, cols, rows_ in LAYOUTS:
        for display in sorted(frames):
            if display not in residuals:
                continue
            ex, ey = residuals[display]
            _, _, full_w, full_h = frames[display]
            w, h = full_w / cols, full_h / rows_
            right, wrong = simulate(ex, ey, full_w, full_h, cols, rows_)
            print(f"{name:<10} {display:>8} {f'{w:.0f}x{h:.0f}':>12} "
                  f"{centre(ex, w) * centre(ey, h):>7.1%}   {right:>9.1%} "
                  f"{wrong:>10.1%} {1 - right - wrong:>12.1%}")


def placement_report(train_rows, test_rows, weights, frames):
    """How far the drawn dot lands from where you were actually looking.

    Reported alongside the spread of what it predicts, because the failure this
    was written for isn't inaccuracy — it's a dot pinned near the middle of the
    screen, which can look respectable on median error while carrying no
    information at all.
    """
    same = train_rows is test_rows
    groups = bursts(train_rows)
    summary = [([st.mean(r["x"][i] for r in g) for i in range(len(AXES))], g[0]["point"], g[0]["display"])
               for g in groups]

    def build(exclude):
        """Fit both placement methods, optionally holding one dot out.

        With sixteen dots total, scoring a fit on the very dots it was fitted to
        flatters it. When there's only one capture, each dot is predicted by a
        fit that never saw it.
        """
        idw_refs, linear = {}, {}
        for i, (x, point, display) in enumerate(summary):
            if i == exclude:
                continue
            idw_refs.setdefault(display, []).append((x, point))
        no_lid = {}
        for display, pts in idw_refs.items():
            def solve(own, cross, index, drop=()):
                """Fit one axis, matching GazeProfile.placement."""
                for terms in shapes(own, cross, drop):
                    got = fit_ls([[evaluate(t, x) for t in terms] for x, _ in pts],
                                 [p[index] for _, p in pts])
                    if got:
                        return terms, got
                return None

            full = (solve(HORIZONTAL, VERTICAL, 0), solve(VERTICAL, HORIZONTAL, 1))
            if all(full):
                linear[display] = full
            # The same selection with the eyelid term removed, so the placement
            # table can say whether it earned its parameter on the axis it was
            # added for rather than only whether the whole thing got better.
            bare = (solve(HORIZONTAL, VERTICAL, 0, drop=(LID_Y,)),
                    solve(VERTICAL, HORIZONTAL, 1, drop=(LID_Y,)))
            if all(bare):
                no_lid[display] = bare
        return idw_refs, linear, no_lid

    def idw(fitted, display, x):
        refs = fitted[0].get(display)
        if not refs:
            return None
        acc_x = acc_y = total = 0.0
        for ref, point in refs:
            d = math.sqrt(sum(((x[i] - ref[i]) * weights[i]) ** 2 for i in range(len(AXES))))
            w = 1 / (d * d + 0.05)
            acc_x += w * point[0]; acc_y += w * point[1]; total += w
        return (acc_x / total, acc_y / total)

    def predict_with(slot):
        def go(fitted, display, x):
            if display not in fitted[slot]:
                return None
            def apply(terms, c):
                return c[0] + sum(c[i + 1] * evaluate(t, x) for i, t in enumerate(terms))
            return tuple(apply(terms, c) for terms, c in fitted[slot][display])
        return go

    lin = predict_with(1)
    bare = predict_with(2)

    # Which fit each test frame is scored against: its own dot held out when
    # train and test are the same capture, otherwise just the one fit.
    if same:
        test_groups = bursts(test_rows)
        plan = [(build(i), g) for i, g in enumerate(test_groups)]
    else:
        plan = [(build(None), test_rows)]

    print("\nplacement — where the debug dot lands, px from the dot you were told to look at"
          + ("  (each dot held out)" if same else ""))
    print(f"{'method':<10} {'err x':>8} {'err y':>8}   {'moves x pred/true':>22}"
          f"   {'moves y pred/true':>22}")
    for name, predict in (("idw", idw), ("no lidY", bare), ("linear", lin)):
        ex, ey, px_, py_, tx_, ty_ = [], [], [], [], [], []
        for fitted, chunk in plan:
            for row in chunk:
                got = predict(fitted, row["display"], row["x"])
                if got is None:
                    continue
                ex.append(abs(got[0] - row["point"][0])); ey.append(abs(got[1] - row["point"][1]))
                px_.append(got[0]); py_.append(got[1])
                tx_.append(row["point"][0]); ty_.append(row["point"][1])
        if not ex:
            print(f"{name:<10} (no fit)")
            continue
        # "moves" is the standard deviation of the predictions against the truth.
        # A dot stuck near the middle of the screen shows up here as a predicted
        # spread far below the true one, however good the median error looks.
        print(f"{name:<10} {st.median(ex):>8.0f} {st.median(ey):>8.0f}   "
              f"{spread(px_):>10.0f} /{spread(tx_):>10.0f}   "
              f"{spread(py_):>10.0f} /{spread(ty_):>10.0f}")

    # A v1 capture has no eyelid column, so the fit that uses one is singular
    # and predicts nothing. Score the tiles against whichever fit this capture
    # can actually support rather than printing an empty table.
    shipping = lin if any(predictor for predictor in
                          (lin(fitted, row["display"], row["x"])
                           for fitted, chunk in plan[:1] for row in chunk[:1])) else bare
    tile_report(plan, shipping, frames)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="*")
    parser.add_argument("--margin", type=float, default=0.85)
    parser.add_argument("--frames", type=int, default=3)
    parser.add_argument("--inset", type=float, default=None,
                        help="override gazeWindowInset when scoring window slots")
    parser.add_argument("--placement", action="store_true",
                        help="score where the debug dot lands instead of only which display")
    args = parser.parse_args()

    if args.inset is not None:
        global GAZE_WINDOW_INSET
        GAZE_WINDOW_INSET = args.inset

    files = args.files or sorted(glob.glob(os.path.join(CAPTURES, "*.csv")))
    if not files:
        raise SystemExit(f"no captures in {CAPTURES} — calibrate once to record one")

    # A cancelled calibration writes a file too. Training on one scores at
    # chance and looks like a broken classifier rather than a broken input.
    full = max((len(coverage(load(f))) for f in files), default=0)
    keep = [f for f in files if len(coverage(load(f))) == full]
    for dropped in [f for f in files if f not in keep]:
        print(f"skipping {os.path.basename(dropped)}: partial capture "
              f"({len(coverage(load(dropped)))} of {full} display/pass combinations)")
    files = keep

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

    if args.placement:
        placement_report(train_rows, test_rows, model["jitter"], arrangement(files[-1]))


if __name__ == "__main__":
    sys.exit(main())
