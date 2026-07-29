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

AXES = ["headX", "headY", "eyeX", "eyeY", "lidY", "faceYaw", "facePitch", "faceRoll"]
CAPTURES = os.path.expanduser("~/Library/Logs/Shiftly-gaze")
FLOOR = 0.02

# Index of each axis within a row's "x", for the fits that care which is which.
HEAD_X, HEAD_Y, EYE_X, EYE_Y, LID_Y, FACE_YAW, FACE_PITCH, FACE_ROLL = range(len(AXES))
HORIZONTAL = [HEAD_X, EYE_X, FACE_YAW]
VERTICAL = [HEAD_Y, EYE_Y, LID_Y, FACE_PITCH]
# Head tilt corrects both directions and carries neither.
TILT = [FACE_ROLL]
POSE = [FACE_YAW, FACE_PITCH, FACE_ROLL]

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
                # different denominator; a v2 has no head pose. Zero-filling
                # keeps both loadable for the display-level scores, which don't
                # depend on either, and a column of zeroes is dropped from the
                # placement fits rather than making them singular.
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

    def ablate(off):
        return norm([0.0 if i in off else between[i] / max(jitter[i], FLOOR)
                     for i in range(len(AXES))])

    return {
        "refs": refs,
        # What shipped first: scaled by how much an axis varies across one
        # display's dots, which counts "tracking where on the screen you look"
        # as noise and buries the pupil terms.
        "spread": norm([between[i] / max(within[i], FLOOR) for i in range(len(AXES))]),
        # Scaled by per-frame jitter instead.
        "jitter": norm([between[i] / max(jitter[i], FLOOR) for i in range(len(AXES))]),
        "equal": [1.0] * len(AXES),
        "eyes_only": [1.0 if i in (EYE_X, EYE_Y, LID_Y) else 0.0 for i in range(len(AXES))],
        "head_only": [1.0 if i in (HEAD_X, HEAD_Y) + tuple(POSE) else 0.0
                      for i in range(len(AXES))],
        # Jitter-scaled with one group switched off, which is how we find out
        # whether adding it bought anything or only added a dimension.
        "no_lid": ablate([LID_Y]),
        "no_pose": ablate(POSE),
        # The other side of the same question: Vision's pose instead of the
        # nose-over-eye-line ratios, rather than alongside them.
        "pose_only": ablate([HEAD_X, HEAD_Y]),
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


def live(terms, pts):
    """Drop terms that never moved, matching GazeProfile.placement.

    An older capture zero-fills the columns it doesn't have, and a column of one
    repeated number is the constant term again, which makes the normal equations
    singular. Dropping the dead term is what lets a v2 capture still be scored
    against the current fit.
    """
    return [t for t in terms
            if spread([evaluate(t, x) for x, _ in pts]) > 1e-6]


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
        idw_refs = {}
        for i, (x, point, display) in enumerate(summary):
            if i == exclude:
                continue
            idw_refs.setdefault(display, []).append((x, point))

        # Each variant is the shipped fit with one group of axes withheld, so
        # the placement table says whether a group earned its parameters rather
        # than only whether the whole thing moved.
        # What ships is the pose-free fit. The rest are kept so the measurement
        # that settled it stays reproducible: Vision's head pose is recorded in
        # every capture and every way of fitting against it scored worse on a
        # held-out calibration. See the note on GazeProfile.fitted. Eighteen
        # dots a display is not many to spend parameters on, so an angle has to
        # beat not only zero but the parameter it costs.
        variants = {"linear (ships)": tuple(POSE), "no lidY": (LID_Y,) + tuple(POSE),
                    "+yaw": (FACE_PITCH, FACE_ROLL),
                    "+yaw+pitch": (FACE_ROLL,),
                    "+all pose": (),
                    "pose replaces head": (HEAD_X, HEAD_Y)}
        fits = {name: {} for name in variants}
        for display, pts in idw_refs.items():
            def solve(own, cross, index, drop=()):
                """Fit one axis, matching GazeProfile.placement."""
                for terms in shapes(own, cross, drop):
                    terms = live(terms, pts)
                    got = fit_ls([[evaluate(t, x) for t in terms] for x, _ in pts],
                                 [p[index] for _, p in pts])
                    if got:
                        return terms, got
                return None

            for name, drop in variants.items():
                both = (solve(HORIZONTAL, VERTICAL + TILT, 0, drop),
                        solve(VERTICAL, HORIZONTAL + TILT, 1, drop))
                if all(both):
                    fits[name][display] = both
        return idw_refs, fits

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

    def predict_with(name):
        def go(fitted, display, x):
            if display not in fitted[1][name]:
                return None
            def apply(terms, c):
                return c[0] + sum(c[i + 1] * evaluate(t, x) for i, t in enumerate(terms))
            return tuple(apply(terms, c) for terms, c in fitted[1][name][display])
        return go

    # Which fit each test frame is scored against: its own dot held out when
    # train and test are the same capture, otherwise just the one fit.
    if same:
        test_groups = bursts(test_rows)
        plan = [(build(i), g) for i, g in enumerate(test_groups)]
    else:
        plan = [(build(None), test_rows)]

    def errors(predict):
        """Absolute residuals per display per axis, plus everything pooled."""
        out = {}
        for fitted, chunk in plan:
            for row in chunk:
                got = predict(fitted, row["display"], row["x"])
                if got is None:
                    continue
                for key in (row["display"], "all"):
                    slot = out.setdefault(key, ([], [], [], [], [], []))
                    slot[0].append(abs(got[0] - row["point"][0]))
                    slot[1].append(abs(got[1] - row["point"][1]))
                    slot[2].append(got[0]); slot[3].append(row["point"][0])
                    slot[4].append(got[1]); slot[5].append(row["point"][1])
        return out

    print("\nplacement — where the debug dot lands, px from the dot you were told to look at"
          + ("  (each dot held out)" if same else ""))
    print(f"{'method':<14} {'err x':>8} {'err y':>8}   {'moves x pred/true':>22}"
          f"   {'moves y pred/true':>22}")
    displays = sorted(frames) or sorted({r["display"] for r in test_rows})
    per_display = {}
    for name in ("idw", "no lidY", "linear (ships)",
                 "+yaw", "+yaw+pitch", "+all pose", "pose replaces head"):
        got = errors(idw if name == "idw" else predict_with(name))
        if "all" not in got:
            print(f"{name:<14} (no fit)")
            continue
        per_display[name] = got
        ex, ey, px_, tx_, py_, ty_ = got["all"]
        # "moves" is the standard deviation of the predictions against the truth.
        # A dot stuck near the middle of the screen shows up here as a predicted
        # spread far below the true one, however good the median error looks.
        print(f"{name:<14} {st.median(ex):>8.0f} {st.median(ey):>8.0f}   "
              f"{spread(px_):>10.0f} /{spread(tx_):>10.0f}   "
              f"{spread(py_):>10.0f} /{spread(ty_):>10.0f}")

    # Pooling the two displays hides the thing worth knowing. The axes that cap
    # window accuracy are one per display and they aren't the same axis, so a
    # change that fixes one and breaks the other reads as no change at all in
    # the median above.
    print("\nplacement by display and axis, median px")
    header = "  ".join(f"{f'{d} x':>8} {f'{d} y':>8}" for d in displays)
    print(f"{'method':<14} {header}")
    for name, got in per_display.items():
        cells = []
        for display in displays:
            if display in got:
                cells.append(f"{st.median(got[display][0]):>8.0f} {st.median(got[display][1]):>8.0f}")
            else:
                cells.append(f"{'-':>8} {'-':>8}")
        print(f"{name:<14} {'  '.join(cells)}")

    tile_report(plan, predict_with("linear (ships)"), frames)


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
    print(f"{'metric':<15} {'weights (' + '/'.join(AXES) + ')':<62} "
          f"{'acc':>6} {'decided':>8} {'wrong':>7} {'lag':>5}")

    for name in ["spread", "jitter", "equal", "eyes_only", "head_only", "no_pose", "pose_only"]:
        weights = model[name]
        for centroid in (False, True):
            result = score(model, weights, test_rows, args.margin, args.frames, centroid)
            label = f"{name}{'+cent' if centroid else ''}"
            shown = "/".join(f"{w:.2f}" for w in weights)
            print(f"{label:<15} {shown:<62} {result['acc']:>6.1%} "
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
