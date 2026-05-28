"""评估长期习惯数据上，个性化历史是否带来增益。

对比:
  1. rule only: 只用当前上下文规则
  2. rule + history features: 使用数据中预测时可获得的历史聚合特征
  3. rule + preference replay: 用训练期反馈更新 PreferenceScorer，再在测试期评估
"""

import argparse
import csv
import os
from collections import defaultdict

from compare_semantic_methods import normalize
from history_booster import StableHistoryBooster
from preference_scorer import PreferenceScorer
from rule_scorer import RuleScorer
from scenes import SCENE_NAMES


def load_rows(path):
    return list(csv.DictReader(open(path, encoding="utf-8-sig")))


def metrics(rows, scorer):
    top1 = top3 = 0
    by_scene = defaultdict(lambda: [0, 0, 0])
    for row in rows:
        scores = scorer(row)
        ranked = sorted(scores, key=scores.get, reverse=True)
        gt = row["ground_truth"]
        top1 += ranked[0] == gt
        top3 += gt in ranked[:3]
        by_scene[gt][0] += 1
        by_scene[gt][1] += ranked[0] == gt
        by_scene[gt][2] += gt in ranked[:3]
    n = len(rows)
    return top1 / n, top3 / n, by_scene


def add_history_boost(base_scores, row, bucket_boost, global_boost):
    scores = dict(base_scores)
    bucket_scene = row.get("bucket_top_scene_before", "")
    bucket_ratio = float(row.get("bucket_top_scene_ratio_before") or 0)
    global_scene = row.get("user_top_scene_before", "")
    global_ratio = float(row.get("user_top_scene_ratio_before") or 0)
    if bucket_scene in scores:
        scores[bucket_scene] += bucket_boost * bucket_ratio
    if global_scene in scores:
        scores[global_scene] += global_boost * global_ratio
    return scores


def add_stable_history_boost(base_scores, row, booster, history_boost):
    return booster.boost(base_scores, row, amount=history_boost)


def train_preference(train_rows, path):
    if os.path.exists(path):
        os.remove(path)
    pref = PreferenceScorer(start_worker=False, persistence_path=path)
    tmp_path = "data/_tmp_longitudinal_train.csv"
    with open(tmp_path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(train_rows[0].keys()))
        writer.writeheader()
        writer.writerows(train_rows)
    pref.fit_from_csv(tmp_path)
    return pref


def print_result(name, result):
    top1, top3, by_scene = result
    print(f"\n{name}")
    print("-" * len(name))
    print(f"Top-1: {top1:.3f}")
    print(f"Top-3: {top3:.3f}")
    worst = []
    for scene, (n, h1, h3) in by_scene.items():
        worst.append((h1 / n, h3 / n, scene, n))
    print("Worst scenes:")
    for h1, h3, scene, n in sorted(worst)[:8]:
        print(f"  {scene:6s} n={n:3d} Top-1={h1:.2f} Top-3={h3:.2f}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default="data/longitudinal_habit_scene_samples.csv")
    parser.add_argument("--preference-path", default="data/preference_longitudinal_train.json")
    parser.add_argument("--bucket-boost", type=float, default=0.55)
    parser.add_argument("--global-boost", type=float, default=0.18)
    parser.add_argument("--stable-history-boost", type=float, default=2.2)
    parser.add_argument("--history-support-k", type=float, default=2.0)
    parser.add_argument("--min-place-confidence", type=float, default=0.55)
    args = parser.parse_args()

    rows = [r for r in load_rows(args.csv) if r.get("event_type") == "listen"]
    train = [r for r in rows if r["split"] == "train"]
    test = [r for r in rows if r["split"] == "test"]
    rule = RuleScorer()
    pref = train_preference(train, args.preference_path)
    stable_history = StableHistoryBooster(
        min_place_confidence=args.min_place_confidence,
        support_k=args.history_support_k,
    ).fit(train)

    print(f"train={len(train)} test={len(test)} users={len(set(r['user_id'] for r in rows))}")

    print_result("rule only", metrics(test, lambda row: rule.score_all(row)))
    print_result(
        "rule + explicit long-term history features",
        metrics(test, lambda row: add_history_boost(rule.score_all(row), row, args.bucket_boost, args.global_boost)),
    )
    print_result(
        "rule + stable hierarchical history booster",
        metrics(test, lambda row: add_stable_history_boost(rule.score_all(row), row, stable_history, args.stable_history_boost)),
    )
    print_result(
        "rule + recent 7d history features",
        metrics(
            test,
            lambda row: add_history_boost(
                rule.score_all(row),
                {
                    **row,
                    "bucket_top_scene_before": row.get("recent_7d_bucket_top_scene_before", ""),
                    "bucket_top_scene_ratio_before": row.get("recent_7d_bucket_top_scene_ratio_before", 0),
                    "user_top_scene_before": row.get("user_top_scene_before", ""),
                    "user_top_scene_ratio_before": row.get("user_top_scene_ratio_before", 0),
                },
                args.bucket_boost,
                args.global_boost,
            ),
        ),
    )

    def rule_pref(row):
        r = normalize(rule.score_all(row))
        p = normalize(pref.score_all(row))
        return {scene: 0.72 * r[scene] + 0.28 * p[scene] for scene in SCENE_NAMES}

    print_result("rule + PreferenceScorer trained on first 90 days", metrics(test, rule_pref))


if __name__ == "__main__":
    main()
