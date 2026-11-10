#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "scikit-learn"]
# ///
"""评估三个手势能否从手表运动数据中识别。用法：uv run analysis/analyze.py data/captures

防虚高的做法：
- 窗口不覆盖提示震动，并用“只震动”轮提供带提示但没有手势的负样本。
- 不用重力特征，否则分类器可能靠每轮的手臂姿势认出是哪一轮。
- 交叉验证按连续时间块分组，相邻样本不会同时出现在训练集和测试集。
"""
from __future__ import annotations

import csv
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import GroupKFold

RATE = 100
WINDOW_S = 1.0
HALF = int(WINDOW_S * RATE / 2)
# 震动余波的保护时间：窗口只能从提示后这么久开始。
HAPTIC_GUARD_S = 0.25
EARLIEST_PEAK_S = HAPTIC_GUARD_S + WINDOW_S / 2
LATEST_PEAK_S = 3.0
BLOCK_REPS = 10
NEGATIVE_BLOCK_S = 60
THRESHOLDS = (0.5, 0.6, 0.7, 0.8, 0.9)
TARGET_RECALL = 0.90
TARGET_FP_PER_10MIN = 1.0
MIN_REPS_PER_GESTURE = 20

GESTURES = ("clench", "double", "open")
NONE = "none"
LABEL_BY_RUN = {
    "clench_still": "clench", "clench_move": "clench",
    "double_still": "double", "double_move": "double",
    "open_still": "open", "open_move": "open",
    "cue_only": NONE,
}
TIMED_RUNS = ("move_only", "daily")


@dataclass
class Run:
    run_id: str
    stamp: str
    time: np.ndarray
    signals: np.ndarray  # ax ay az rx ry rz
    cues: list[tuple[int, float]]
    invalid: set[int]


@dataclass
class Windows:
    features: list[np.ndarray]
    labels: list[str]
    groups: list[str]
    conditions: list[str]


def load_runs(directory: Path) -> list[Run]:
    runs = []
    for path in sorted(directory.glob("*.samples.csv")):
        match = re.match(r"(.+)--(\d{8}-\d{6})\.samples\.csv$", path.name)
        if not match:
            continue
        raw = np.genfromtxt(path, delimiter=",", skip_header=1, invalid_raise=False)
        if raw.ndim != 2 or len(raw) < RATE * 3:
            print(f"跳过数据太少的文件：{path.name}")
            continue
        cues, invalid = [], set()
        with path.with_name(path.name.replace(".samples.csv", ".events.csv")).open() as handle:
            for row in csv.DictReader(handle):
                if row["type"] == "cue":
                    cues.append((int(row["index"]), float(row["time"])))
                elif row["type"] == "invalid":
                    invalid.add(int(row["index"]))
        runs.append(Run(match[1], match[2], raw[:, 0], raw[:, 1:7], cues, invalid))
    return runs


def high_pass(signals: np.ndarray) -> np.ndarray:
    """去掉慢速转腕，只留手势引起的快速变化。"""
    kernel = np.ones(31) / 31
    trend = np.column_stack([np.convolve(signals[:, i], kernel, mode="same") for i in range(signals.shape[1])])
    return signals - trend


def energy(signals: np.ndarray) -> np.ndarray:
    filtered = high_pass(signals)
    # 加速度单位是 g、角速度单位是弧度/秒，数值量级接近，直接相加。
    return np.linalg.norm(filtered[:, :3], axis=1) + np.linalg.norm(filtered[:, 3:], axis=1)


def features(window: np.ndarray) -> np.ndarray:
    filtered = high_pass(window)
    values = []
    frequencies = np.fft.rfftfreq(len(window), 1 / RATE)
    for channel in filtered.T:
        spectrum = np.abs(np.fft.rfft(channel * np.hanning(len(channel)))) ** 2
        values += [channel.std(), np.ptp(channel), np.abs(channel).mean()]
        for low, high in ((1, 5), (5, 15), (15, 30), (30, 50)):
            values.append(spectrum[(frequencies >= low) & (frequencies < high)].sum())
    envelope = energy(window)
    # 连续抓握有两个峰，单次抓握只有一个。
    order = np.argsort(envelope)[::-1]
    second = next((i for i in order if abs(i - order[0]) > 10), order[0])
    values += [envelope[order[0]], envelope[second], envelope[second] / (envelope[order[0]] + 1e-9), abs(second - order[0]) / RATE]
    return np.array(values)


def window_at(signals: np.ndarray, center: int) -> np.ndarray | None:
    if center - HALF < 0 or center + HALF > len(signals):
        return None
    return signals[center - HALF:center + HALF]


def build_windows(runs: list[Run]) -> tuple[Windows, Counter, float, dict[str, float]]:
    data = Windows([], [], [], [])
    skipped: Counter = Counter()
    peaks = []
    cued = [run for run in runs if run.run_id in LABEL_BY_RUN]
    for run in cued:
        label = LABEL_BY_RUN[run.run_id]
        condition = run.run_id.split("_")[1] if label != NONE else "cue_only"
        envelope = energy(run.signals)
        for position, (index, cue_time) in enumerate(run.cues):
            if index in run.invalid:
                skipped["作废"] += 1
                continue
            mask = (run.time >= cue_time + EARLIEST_PEAK_S) & (run.time <= cue_time + LATEST_PEAK_S)
            if not mask.any():
                skipped["提示后数据不足"] += 1
                continue
            # 提示后保护时间内就出现最大峰，说明手势做早了，窗口会包含震动，只能丢弃。
            early = (run.time >= cue_time + HAPTIC_GUARD_S) & (run.time < cue_time + EARLIEST_PEAK_S)
            candidates = np.flatnonzero(mask)
            center = candidates[np.argmax(envelope[candidates])]
            if label != NONE and early.any() and envelope[early].max() > envelope[center] * 1.5:
                skipped[f"{label} 做得太早"] += 1
                continue
            window = window_at(run.signals, center)
            if window is None:
                skipped["窗口超界"] += 1
                continue
            if label != NONE:
                peaks.append(envelope[center])
            data.features.append(features(window))
            data.labels.append(label)
            data.groups.append(f"{run.run_id}-{run.stamp}-{position // BLOCK_REPS}")
            data.conditions.append(condition)

    # 只有比大多数手势峰还强的动作才会进入分类，实际运行也会这样触发。
    trigger = float(np.percentile(peaks, 5)) if peaks else 0.0
    minutes: dict[str, float] = {}
    for run in (r for r in runs if r.run_id in TIMED_RUNS):
        minutes[run.run_id] = minutes.get(run.run_id, 0.0) + (run.time[-1] - run.time[0]) / 60
        envelope = energy(run.signals)
        index = HALF
        while index < len(envelope) - HALF:
            segment = envelope[index:index + RATE]
            peak = index + int(np.argmax(segment))
            if envelope[peak] >= trigger:
                window = window_at(run.signals, peak)
                if window is not None:
                    data.features.append(features(window))
                    data.labels.append(NONE)
                    data.groups.append(f"{run.run_id}-{run.stamp}-{int((run.time[peak] - run.time[0]) // NEGATIVE_BLOCK_S)}")
                    data.conditions.append(run.run_id)
                index = peak + RATE
            else:
                index += RATE
    return data, skipped, trigger, minutes


def cross_validate(data: Windows, folds: int = 5, seed: int = 0) -> tuple[np.ndarray, list[str]]:
    x = np.array(data.features)
    y = np.array(data.labels)
    groups = np.array(data.groups)
    classes = sorted(set(data.labels))
    probabilities = np.zeros((len(y), len(classes)))
    for train, test in GroupKFold(n_splits=min(folds, len(set(data.groups)))).split(x, y, groups):
        model = RandomForestClassifier(n_estimators=300, class_weight="balanced_subsample", random_state=seed, n_jobs=-1)
        model.fit(x[train], y[train])
        lookup = {name: i for i, name in enumerate(model.classes_)}
        result = model.predict_proba(x[test])
        for column, name in enumerate(classes):
            if name in lookup:
                probabilities[test, column] = result[:, lookup[name]]
    return probabilities, classes


def predict(probabilities: np.ndarray, classes: list[str], threshold: float) -> np.ndarray:
    """最可能的手势概率够高才算手势，否则视为没有手势。"""
    gesture_columns = [i for i, name in enumerate(classes) if name != NONE]
    best = np.array(gesture_columns)[np.argmax(probabilities[:, gesture_columns], axis=1)]
    confident = probabilities[np.arange(len(best)), best] >= threshold
    return np.where(confident, np.array(classes)[best], NONE)


def evaluate(data: Windows, probabilities: np.ndarray, classes: list[str], negative_minutes: float) -> list[dict]:
    labels = np.array(data.labels)
    conditions = np.array(data.conditions)
    results = []
    for threshold in THRESHOLDS:
        predicted = predict(probabilities, classes, threshold)
        row: dict = {"threshold": threshold}
        for gesture in GESTURES:
            mask = labels == gesture
            row[gesture] = float((predicted[mask] == gesture).mean()) if mask.any() else None
        timed = np.isin(conditions, TIMED_RUNS)
        false_positives = int((predicted[timed] != NONE).sum())
        row["false_positives"] = false_positives
        row["fp_per_10min"] = false_positives / negative_minutes * 10 if negative_minutes > 0 else None
        cue_mask = conditions == "cue_only"
        row["cue_only_fp"] = float((predicted[cue_mask] != NONE).mean()) if cue_mask.any() else None
        results.append(row)
    return results


def report(runs: list[Run]) -> int:
    print("已加载：", dict(Counter(run.run_id for run in runs)))
    data, skipped, trigger, minutes = build_windows(runs)
    counts = Counter(data.labels)
    print("样本数：", dict(counts), "| 丢弃：", dict(skipped))
    print(f"触发阈值 {trigger:.3f} | 负样本时长（分钟）：", {k: round(v, 1) for k, v in minutes.items()})

    missing = [g for g in GESTURES if counts[g] < MIN_REPS_PER_GESTURE]
    if missing or counts[NONE] == 0:
        print(f"\n数据不足，无法评估：手势 {missing or '足够'}，负样本 {counts[NONE]} 个。")
        return 2

    negative_minutes = sum(minutes.values())
    probabilities, classes = cross_validate(data)
    results = evaluate(data, probabilities, classes, negative_minutes)

    print("\n阈值   抓握   连续   张开   误触/10分钟   只震动误判")
    for row in results:
        fp = "无数据" if row["fp_per_10min"] is None else f"{row['fp_per_10min']:.1f}"
        cue = "无数据" if row["cue_only_fp"] is None else f"{row['cue_only_fp']:.0%}"
        print(f"{row['threshold']:.1f}   {row['clench']:.0%}   {row['double']:.0%}   {row['open']:.0%}   {fp:>8}   {cue:>8}")

    passing = [r for r in results if r["fp_per_10min"] is not None and r["fp_per_10min"] <= TARGET_FP_PER_10MIN]
    chosen = passing[0] if passing else results[-1]
    predicted = predict(probabilities, classes, chosen["threshold"])
    labels = np.array(data.labels)
    conditions = np.array(data.conditions)

    print(f"\n按阈值 {chosen['threshold']:.1f} 的混淆情况（行是真实，列是判定）：")
    names = list(GESTURES) + [NONE]
    print("        " + "".join(f"{n:>8}" for n in names))
    for truth in names:
        mask = labels == truth
        print(f"{truth:>8}" + "".join(f"{int((predicted[mask] == p).sum()):>8}" for p in names))

    print("\n静止与移动时的识别率：")
    for gesture in GESTURES:
        parts = []
        for condition in ("still", "move"):
            mask = (labels == gesture) & (conditions == condition)
            parts.append(f"{condition} {(predicted[mask] == gesture).mean():.0%}（{mask.sum()}）" if mask.any() else f"{condition} 无数据")
        print(f"  {gesture}: " + "，".join(parts))

    print(f"\n结论（目标：识别率不低于 {TARGET_RECALL:.0%}，误触不超过 {TARGET_FP_PER_10MIN:g} 次/10 分钟）：")
    fp_ok = chosen["fp_per_10min"] is not None and chosen["fp_per_10min"] <= TARGET_FP_PER_10MIN
    if chosen["fp_per_10min"] is None:
        print("  误触：没有“只移动”或“日常操作”数据，无法判断")
    else:
        print(f"  误触：{chosen['fp_per_10min']:.1f} 次/10 分钟（共 {negative_minutes:.1f} 分钟），{'达标' if fp_ok else '未达标'}")
    for gesture in GESTURES:
        print(f"  {gesture}: {chosen[gesture]:.0%}，{'达标' if chosen[gesture] >= TARGET_RECALL and fp_ok else '未达标'}")
    print("  注意：这是单人离线结果，同一批录制做交叉验证，会比换天、换人、实时运行时乐观。")
    return 0


def main() -> int:
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else "data/captures")
    runs = load_runs(directory)
    if not runs:
        print(f"{directory} 里没有采集文件。")
        return 2
    return report(runs)


if __name__ == "__main__":
    raise SystemExit(main())
