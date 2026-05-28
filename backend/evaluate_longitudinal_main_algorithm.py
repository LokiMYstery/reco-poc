"""在长期习惯数据上评估主算法。

主算法:
  final_score = rule_weight * rule_score
              + semantic_weight * semantic_score
              + preference_weight * preference_score

其中 preference 只用 train split 训练，再在 test split 上评估。
"""

import argparse
import csv
import os

from compare_semantic_methods import normalize
from history_booster import StableHistoryBooster
from preference_scorer import PreferenceScorer
from prototype_semantic_scorer import PrototypeSemanticScorer, Qwen3PrototypeSemanticScorer
from qwen3_semantic_scorer import QWEN3_INSTRUCTION_VARIANTS
from rule_scorer import RuleScorer
from semantic_scorer import SemanticScorer
from scenes import SCENE_NAMES


def load_listen_rows(path):
    rows = list(csv.DictReader(open(path, encoding="utf-8-sig")))
    return [row for row in rows if row.get("event_type") == "listen"]


def write_rows(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def train_preference(train_rows, path):
    if os.path.exists(path):
        os.remove(path)
    train_path = "data/_tmp_longitudinal_main_train.csv"
    write_rows(train_path, train_rows)
    scorer = PreferenceScorer(start_worker=False, persistence_path=path)
    scorer.fit_from_csv(train_path)
    return scorer


def build_semantic(args):
    if args.semantic == "embedding":
        return SemanticScorer(cache_path="data/scene_vectors.npy")
    if args.semantic == "embedding-proto":
        return PrototypeSemanticScorer(
            cache_path="data/minilm_prototype_scene_vectors.npy",
            aggregate=args.prototype_aggregate,
        )
    if args.semantic == "qwen3-proto":
        return Qwen3PrototypeSemanticScorer(
            model_name=args.qwen_model,
            cache_path=f"data/{args.qwen_model.replace('/', '_')}_prototype_scene_vectors.npy",
            aggregate=args.prototype_aggregate,
            instruction_variant=args.qwen_instruction,
            local_files_only=not args.qwen_online,
        )
    raise ValueError(args.semantic)


def fuse(rule_scores, semantic_scores, preference_scores, weights, history_scores=None):
    wr, ws, wp, wh = weights
    r = normalize(rule_scores)
    s = normalize(semantic_scores)
    p = normalize(preference_scores)
    h = normalize(history_scores) if history_scores else {scene: 0.5 for scene in SCENE_NAMES}
    total = wr + ws + wp + wh
    if total <= 0:
        total = 1.0
    return {
        scene: (
            wr * r.get(scene, 0.5)
            + ws * s.get(scene, 0.5)
            + wp * p.get(scene, 0.5)
            + wh * h.get(scene, 0.5)
        ) / total
        for scene in SCENE_NAMES
    }


def evaluate(rows, semantic, preference, weights, history_booster=None, limit=0):
    rule = RuleScorer()
    if limit and limit > 0:
        rows = rows[:limit]

    semantic_top1 = semantic_top3 = fused_top1 = fused_top3 = 0
    details = []
    for row in rows:
        gt = row["ground_truth"]
        semantic_scores = semantic.score_all(row)
        preference_scores = preference.score_all(row)
        history_scores = history_booster.score_all(row) if history_booster else None
        final_scores = fuse(rule.score_all(row), semantic_scores, preference_scores, weights, history_scores)

        semantic_ranked = sorted(semantic_scores, key=semantic_scores.get, reverse=True)
        fused_ranked = sorted(final_scores, key=final_scores.get, reverse=True)
        semantic_top1 += semantic_ranked[0] == gt
        semantic_top3 += gt in semantic_ranked[:3]
        fused_top1 += fused_ranked[0] == gt
        fused_top3 += gt in fused_ranked[:3]

        details.append({
            "session_id": row.get("session_id", ""),
            "user_id": row.get("user_id", ""),
            "date": row.get("date", ""),
            "time": row.get("time", ""),
            "ground_truth": gt,
            "semantic_top1": semantic_ranked[0],
            "semantic_top3": "|".join(semantic_ranked[:3]),
            "fused_top1": fused_ranked[0],
            "fused_top3": "|".join(fused_ranked[:3]),
            "is_disruption_week": row.get("is_disruption_week", ""),
            "is_disruption_window": row.get("is_disruption_window", ""),
        })

    n = len(rows)
    return {
        "samples": n,
        "semantic_top1": semantic_top1 / n if n else 0.0,
        "semantic_top3": semantic_top3 / n if n else 0.0,
        "fused_top1": fused_top1 / n if n else 0.0,
        "fused_top3": fused_top3 / n if n else 0.0,
    }, details


def save_details(path, details):
    if not details:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(details[0].keys()))
        writer.writeheader()
        writer.writerows(details)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default="data/longitudinal_habit_scene_samples.csv")
    parser.add_argument("--semantic", choices=["embedding", "embedding-proto", "qwen3-proto"], default="embedding-proto")
    parser.add_argument("--rule-weight", type=float, default=0.60)
    parser.add_argument("--semantic-weight", type=float, default=0.25)
    parser.add_argument("--preference-weight", type=float, default=0.15)
    parser.add_argument("--stable-history-weight", type=float, default=0.0)
    parser.add_argument("--prototype-aggregate", choices=["max", "mean", "max_top2", "softmax"], default="max")
    parser.add_argument("--qwen-model", default="Qwen/Qwen3-Embedding-0.6B")
    parser.add_argument("--qwen-instruction", default="retrieval", choices=list(QWEN3_INSTRUCTION_VARIANTS.keys()))
    parser.add_argument("--qwen-online", action="store_true")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--preference-path", default="data/preference_longitudinal_main_train.json")
    parser.add_argument("--out", default="data/longitudinal_main_algorithm_predictions.csv")
    args = parser.parse_args()

    rows = load_listen_rows(args.csv)
    train = [row for row in rows if row["split"] == "train"]
    test = [row for row in rows if row["split"] == "test"]
    preference = train_preference(train, args.preference_path)
    history_booster = None
    if args.stable_history_weight > 0:
        history_booster = StableHistoryBooster(support_k=2.0).fit(train)
    semantic = build_semantic(args)
    metrics, details = evaluate(
        test,
        semantic,
        preference,
        (args.rule_weight, args.semantic_weight, args.preference_weight, args.stable_history_weight),
        history_booster=history_booster,
        limit=args.limit,
    )
    save_details(args.out, details)

    print(f"semantic={args.semantic}")
    print(f"train={len(train)} test={len(test)} evaluated={metrics['samples']}")
    print(f"semantic Top-1: {metrics['semantic_top1']:.3f}")
    print(f"semantic Top-3: {metrics['semantic_top3']:.3f}")
    print(f"fused Top-1:    {metrics['fused_top1']:.3f}")
    print(f"fused Top-3:    {metrics['fused_top3']:.3f}")
    print(f"details: {args.out}")


if __name__ == "__main__":
    main()
