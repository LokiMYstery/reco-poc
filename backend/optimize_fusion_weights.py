"""在缺失/噪声数据上搜索 rule + semantic + preference 的融合权重。

默认使用 sparse 数据做一次 train/validation split:
  - train: 用于回放训练 preference scorer
  - validation: 用于搜索融合权重

示例:
  python3 optimize_fusion_weights.py --csv data/realistic_scene_samples_sparse.csv
"""

import argparse
import csv
import os
import random
from typing import Dict, List, Tuple

from preference_scorer import PreferenceScorer
from rule_scorer import RuleScorer
from scenes import SCENE_NAMES
from semantic_scorer import SemanticScorer


def load_rows(path: str) -> List[Dict]:
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def save_rows(path: str, rows: List[Dict]):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def stratified_split(rows: List[Dict], train_ratio: float, seed: int):
    random.seed(seed)
    by_scene = {}
    for row in rows:
        by_scene.setdefault(row["ground_truth"], []).append(row)
    train, val = [], []
    for scene_rows in by_scene.values():
        random.shuffle(scene_rows)
        cut = int(len(scene_rows) * train_ratio)
        train.extend(scene_rows[:cut])
        val.extend(scene_rows[cut:])
    random.shuffle(train)
    random.shuffle(val)
    return train, val


def normalize(scores: Dict[str, float]) -> Dict[str, float]:
    values = list(scores.values())
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return {k: 0.5 for k in scores}
    return {k: (v - lo) / (hi - lo) for k, v in scores.items()}


def fuse(rule, semantic, preference, weights):
    wr, ws, wp = weights
    r = normalize(rule)
    s = normalize(semantic)
    p = normalize(preference)
    return {
        scene: wr * r.get(scene, 0.5) + ws * s.get(scene, 0.5) + wp * p.get(scene, 0.5)
        for scene in SCENE_NAMES
    }


def metrics(score_sets, weights):
    top1 = 0
    top3 = 0
    by_scene = {scene: {"n": 0, "top1": 0, "top3": 0} for scene in SCENE_NAMES}
    for item in score_sets:
        final_scores = fuse(item["rule"], item["semantic"], item["preference"], weights)
        ranked = sorted(final_scores, key=final_scores.get, reverse=True)
        gt = item["ground_truth"]
        hit1 = ranked[0] == gt
        hit3 = gt in ranked[:3]
        top1 += int(hit1)
        top3 += int(hit3)
        by_scene[gt]["n"] += 1
        by_scene[gt]["top1"] += int(hit1)
        by_scene[gt]["top3"] += int(hit3)
    n = len(score_sets)
    return {
        "top1": top1 / n if n else 0.0,
        "top3": top3 / n if n else 0.0,
        "by_scene": by_scene,
    }


def grid_weights(step: float):
    units = int(round(1 / step))
    for ir in range(units + 1):
        for is_ in range(units - ir + 1):
            ip = units - ir - is_
            yield (ir * step, is_ * step, ip * step)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default="data/realistic_scene_samples_sparse.csv")
    parser.add_argument("--train-ratio", type=float, default=0.7)
    parser.add_argument("--seed", type=int, default=20260522)
    parser.add_argument("--step", type=float, default=0.05)
    parser.add_argument("--out", default="data/fusion_weight_search.csv")
    parser.add_argument("--preference-path", default="data/preference_sparse_train.json")
    args = parser.parse_args()

    rows = load_rows(args.csv)
    train, val = stratified_split(rows, args.train_ratio, args.seed)
    train_path = "data/_tmp_sparse_train.csv"
    save_rows(train_path, train)

    if os.path.exists(args.preference_path):
        os.remove(args.preference_path)
    preference = PreferenceScorer(start_worker=False, persistence_path=args.preference_path)
    preference.fit_from_csv(train_path)

    rule = RuleScorer()
    semantic = SemanticScorer(cache_path="data/scene_vectors.npy")

    score_sets = []
    for row in val:
        score_sets.append({
            "ground_truth": row["ground_truth"],
            "rule": rule.score_all(row),
            "semantic": semantic.score_all(row),
            "preference": preference.score_all(row),
        })

    rows_out = []
    best = None
    for weights in grid_weights(args.step):
        m = metrics(score_sets, weights)
        row = {
            "rule_weight": round(weights[0], 3),
            "semantic_weight": round(weights[1], 3),
            "preference_weight": round(weights[2], 3),
            "top1": round(m["top1"], 6),
            "top3": round(m["top3"], 6),
        }
        rows_out.append(row)
        if best is None or (m["top1"], m["top3"]) > (best["metrics"]["top1"], best["metrics"]["top3"]):
            best = {"weights": weights, "metrics": m}

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows_out[0].keys()))
        writer.writeheader()
        writer.writerows(sorted(rows_out, key=lambda x: (x["top1"], x["top3"]), reverse=True))

    print(f"train={len(train)} validation={len(val)}")
    print("best weights:")
    print(f"  rule={best['weights'][0]:.2f}, semantic={best['weights'][1]:.2f}, preference={best['weights'][2]:.2f}")
    print(f"  Top-1={best['metrics']['top1']:.3f}, Top-3={best['metrics']['top3']:.3f}")
    print(f"all results: {args.out}")


if __name__ == "__main__":
    main()
