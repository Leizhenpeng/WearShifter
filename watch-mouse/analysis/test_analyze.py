#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "scikit-learn"]
# ///
"""用合成数据检查分析工具本身。这些数字只说明工具没有算错，不代表真实手势的识别率。"""
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import analyze


def burst(length, center, frequency, amplitude):
    t = (np.arange(length) - center) / analyze.RATE
    return amplitude * np.exp(-((t / 0.05) ** 2)) * np.sin(2 * np.pi * frequency * t)


def make_run(run_id, stamp, reps, rng, shape, haptic=0.0, cue_delay=1.5):
    """shape(index) 返回相对提示的手势波形参数列表：(延迟秒, 频率, 幅度)。"""
    length = int((3 + reps * 4 + 2) * analyze.RATE)
    time = 1000 + np.arange(length) / analyze.RATE
    signals = rng.normal(0, 0.01, (length, 6))
    cues = []
    for index in range(reps):
        cue_at = 3 + index * 4
        cues.append((index, 1000 + cue_at))
        start = int(cue_at * analyze.RATE)
        signals[:, 0] += burst(length, start + 5, 40, haptic)
        for delay, frequency, amplitude in shape(index):
            jitter = rng.normal(0, 0.1)
            center = start + int((cue_delay + delay + jitter) * analyze.RATE)
            for channel in (0, 3, 4):
                signals[:, channel] += burst(length, center, frequency, amplitude * rng.uniform(0.8, 1.2))
    return analyze.Run(run_id, stamp, time, signals, cues, set())


def make_timed(run_id, stamp, minutes, rng):
    length = int(minutes * 60 * analyze.RATE)
    time = 1000 + np.arange(length) / analyze.RATE
    signals = rng.normal(0, 0.01, (length, 6))
    # 偶尔有不像手势的慢动作。
    for center in rng.integers(100, length - 100, int(minutes * 12)):
        signals[:, 5] += burst(length, center, 3, 1.0)
    return analyze.Run(run_id, stamp, time, signals, [], set())


def separable_runs(rng, haptic=0.0):
    shapes = {
        "clench": lambda _: [(0, 20, 1.0)],
        "double": lambda _: [(0, 20, 1.0), (0.3, 20, 1.0)],
        "open": lambda _: [(0, 8, 0.6)],
    }
    runs = []
    for label, shape in shapes.items():
        runs.append(make_run(f"{label}_still", "20260101-000000", 30, rng, shape, haptic))
        runs.append(make_run(f"{label}_move", "20260101-000100", 20, rng, shape, haptic))
    runs.append(make_run("cue_only", "20260101-000200", 30, rng, lambda _: [], haptic))
    runs.append(make_timed("move_only", "20260101-000300", 3, rng))
    return runs


def scores(runs):
    data, _, _, minutes = analyze.build_windows(runs)
    probabilities, classes = analyze.cross_validate(data)
    return analyze.evaluate(data, probabilities, classes, sum(minutes.values()))[0], data


def test_separable_gestures_score_high():
    row, _ = scores(separable_runs(np.random.default_rng(1)))
    for gesture in analyze.GESTURES:
        assert row[gesture] > 0.9, row
    assert row["cue_only_fp"] < 0.1, row


def test_identical_gestures_stay_near_chance():
    """三类手势波形相同且标签无意义时，分数高就说明工具有泄漏。"""
    rng = np.random.default_rng(2)
    same = lambda _: [(0, 20, 1.0)]
    runs = []
    for label in analyze.GESTURES:
        runs.append(make_run(f"{label}_still", "20260101-000000", 30, rng, same))
        runs.append(make_run(f"{label}_move", "20260101-000100", 20, rng, same))
    runs.append(make_run("cue_only", "20260101-000200", 30, rng, lambda _: []))
    runs.append(make_timed("move_only", "20260101-000300", 3, rng))
    data, _, _, _ = analyze.build_windows(runs)
    probabilities, classes = analyze.cross_validate(data)
    predicted = np.array(classes)[np.argmax(probabilities, axis=1)]
    labels = np.array(data.labels)
    mask = np.isin(labels, analyze.GESTURES)
    accuracy = (predicted[mask] == labels[mask]).mean()
    assert accuracy < 0.5, accuracy


def test_haptic_alone_is_not_learned_as_gesture():
    """震动很强时，“只震动”轮也不能被判成手势。"""
    row, _ = scores(separable_runs(np.random.default_rng(3), haptic=3.0))
    assert row["cue_only_fp"] < 0.1, row


def test_windows_never_cover_the_cue():
    runs = separable_runs(np.random.default_rng(4))
    for run in runs:
        for _, cue in run.cues:
            mask = (run.time >= cue + analyze.EARLIEST_PEAK_S) & (run.time <= cue + analyze.LATEST_PEAK_S)
            first = run.time[np.flatnonzero(mask)[0]]
            assert first - analyze.WINDOW_S / 2 >= cue + analyze.HAPTIC_GUARD_S - 0.011


def test_load_real_file_format_and_invalid_mark():
    with tempfile.TemporaryDirectory() as folder:
        directory = Path(folder)
        with (directory / "clench_still--20260101-000000.samples.csv").open("w") as handle:
            handle.write("time,ax,ay,az,rx,ry,rz,gx,gy,gz\n")
            for i in range(600):
                handle.write(f"{i / 100:.4f},0,0,0,0,0,0,0,0,-1\n")
        (directory / "clench_still--20260101-000000.events.csv").write_text(
            "time,type,index\n,start,\n3.0000,cue,0\n3.5000,invalid,0\n5.9000,end,\n"
        )
        runs = analyze.load_runs(directory)
        assert len(runs) == 1
        assert runs[0].signals.shape == (600, 6)
        assert runs[0].cues == [(0, 3.0)] and runs[0].invalid == {0}
        data, skipped, _, _ = analyze.build_windows(runs)
        assert not data.labels and skipped["作废"] == 1


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print("通过", test.__name__)
