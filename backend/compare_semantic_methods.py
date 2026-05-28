"""对比 Embedding 语义通道和 DeepSeek API 语义通道。

示例:
  python3 compare_semantic_methods.py --semantic deepseek --limit 30
  python3 compare_semantic_methods.py --semantic embedding --limit 200
  python3 compare_semantic_methods.py --semantic both --limit 30

DeepSeek 需要:
  export DEEPSEEK_API_KEY="your-key"
"""

import argparse
import csv
import os
import time
from typing import Dict, List, Tuple

from llm_scorer import DeepSeekScorer
from preference_scorer import PreferenceScorer
from prototype_semantic_scorer import PrototypeSemanticScorer, Qwen3PrototypeSemanticScorer
from qwen3_semantic_scorer import Qwen3SemanticScorer
from rule_scorer import RuleScorer
from scenes import SCENE_NAMES
from semantic_scorer import SemanticScorer


def load_rows(path: str, limit: int = 0) -> List[Dict]:
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    if limit and limit > 0:
        return rows[:limit]
    return rows


def normalize(scores: Dict[str, float]) -> Dict[str, float]:
    values = list(scores.values())
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return {k: 0.5 for k in scores}
    return {k: (v - lo) / (hi - lo) for k, v in scores.items()}


def fuse_scores(
    semantic_scores: Dict[str, float],
    preference_scores: Dict[str, float],
    semantic_weight: float = 0.75,
    rule_scores: Dict[str, float] = None,
    rule_weight: float = 0.0,
    preference_weight: float = None,
) -> Dict[str, float]:
    sem = normalize(semantic_scores)
    pref = normalize(preference_scores)
    rule = normalize(rule_scores) if rule_scores else {scene: 0.5 for scene in SCENE_NAMES}
    pref_weight = 1.0 - semantic_weight - rule_weight if preference_weight is None else preference_weight
    return {
        scene: (
            rule_weight * rule.get(scene, 0.5)
            + semantic_weight * sem.get(scene, 0.5)
            + pref_weight * pref.get(scene, 0.5)
        )
        for scene in SCENE_NAMES
    }


def adaptive_fuse_scores(
    semantic_scores: Dict[str, float],
    preference_scores: Dict[str, float],
    rule_scores: Dict[str, float],
    semantic_weight: float,
    rule_weight: float,
    preference_weight: float,
    min_semantic_margin: float = 0.08,
) -> Dict[str, float]:
    sem_values = sorted(normalize(semantic_scores).values(), reverse=True)
    margin = sem_values[0] - sem_values[1] if len(sem_values) >= 2 else 0.0
    if margin < min_semantic_margin:
        total = rule_weight + preference_weight
        return fuse_scores(
            semantic_scores,
            preference_scores,
            semantic_weight=0.0,
            rule_scores=rule_scores,
            rule_weight=rule_weight / total,
            preference_weight=preference_weight / total,
        )
    return fuse_scores(
        semantic_scores,
        preference_scores,
        semantic_weight=semantic_weight,
        rule_scores=rule_scores,
        rule_weight=rule_weight,
        preference_weight=preference_weight,
    )


def evaluate(
    rows: List[Dict],
    semantic_scorer,
    preference_scorer: PreferenceScorer,
    semantic_weight: float,
    rule_scorer: RuleScorer = None,
    rule_weight: float = 0.0,
    preference_weight: float = None,
    adaptive_semantic: bool = False,
    min_semantic_margin: float = 0.08,
) -> Tuple[Dict, List[Dict]]:
    top1 = 0
    top3 = 0
    semantic_top1 = 0
    semantic_top3 = 0
    details = []
    total_latency = 0.0

    for row in rows:
        start = time.time()
        semantic_scores = semantic_scorer.score_all(row)
        total_latency += time.time() - start
        preference_scores = preference_scorer.score_all(row)
        rule_scores = rule_scorer.score_all(row) if rule_scorer else None
        if adaptive_semantic and rule_scores is not None:
            final_scores = adaptive_fuse_scores(
                semantic_scores,
                preference_scores,
                rule_scores,
                semantic_weight,
                rule_weight,
                preference_weight if preference_weight is not None else 1.0 - semantic_weight - rule_weight,
                min_semantic_margin=min_semantic_margin,
            )
        else:
            final_scores = fuse_scores(
                semantic_scores,
                preference_scores,
                semantic_weight,
                rule_scores=rule_scores,
                rule_weight=rule_weight,
                preference_weight=preference_weight,
            )

        sem_ranked = sorted(semantic_scores.items(), key=lambda x: x[1], reverse=True)
        ranked = sorted(final_scores.items(), key=lambda x: x[1], reverse=True)
        gt = row["ground_truth"]
        if sem_ranked[0][0] == gt:
            semantic_top1 += 1
        if gt in [name for name, _ in sem_ranked[:3]]:
            semantic_top3 += 1
        if ranked[0][0] == gt:
            top1 += 1
        if gt in [name for name, _ in ranked[:3]]:
            top3 += 1

        details.append({
            "sample_id": row.get("sample_id", ""),
            "ground_truth": gt,
            "semantic_top1": sem_ranked[0][0],
            "semantic_top1_score": round(sem_ranked[0][1], 4),
            "fused_top1": ranked[0][0],
            "fused_top1_score": round(ranked[0][1], 4),
            "fused_top3": "|".join(name for name, _ in ranked[:3]),
        })

    n = len(rows)
    metrics = {
        "samples": n,
        "semantic_top1": semantic_top1 / n if n else 0.0,
        "semantic_top3": semantic_top3 / n if n else 0.0,
        "fused_top1": top1 / n if n else 0.0,
        "fused_top3": top3 / n if n else 0.0,
        "avg_semantic_latency_ms": 1000 * total_latency / n if n else 0.0,
    }
    return metrics, details


def print_metrics(name: str, metrics: Dict):
    print(f"\n{name}")
    print("-" * len(name))
    print(f"samples: {metrics['samples']}")
    print(f"semantic Top-1: {metrics['semantic_top1']:.3f}")
    print(f"semantic Top-3: {metrics['semantic_top3']:.3f}")
    print(f"fused Top-1:    {metrics['fused_top1']:.3f}")
    print(f"fused Top-3:    {metrics['fused_top3']:.3f}")
    print(f"avg latency:    {metrics['avg_semantic_latency_ms']:.0f} ms/sample")


def save_details(path: str, details: List[Dict]):
    if not details:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(details[0].keys()))
        writer.writeheader()
        writer.writerows(details)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default="data/realistic_scene_samples.csv")
    parser.add_argument("--semantic", choices=["embedding", "embedding-proto", "qwen3", "qwen3-proto", "deepseek", "both"], default="both")
    parser.add_argument("--limit", type=int, default=30, help="DeepSeek有成本，默认只评测前30条。0表示全量。")
    parser.add_argument("--semantic-weight", type=float, default=0.75)
    parser.add_argument("--rule-weight", type=float, default=0.0)
    parser.add_argument("--preference-weight", type=float, default=None)
    parser.add_argument("--adaptive-semantic", action="store_true")
    parser.add_argument("--min-semantic-margin", type=float, default=0.08)
    parser.add_argument("--prototype-aggregate", choices=["max", "mean", "max_top2", "softmax"], default="max_top2")
    parser.add_argument("--qwen-instruction", default="short", help="Qwen instruction variant: short/long/retrieval/sparse/none or custom prompt")
    parser.add_argument("--qwen-model", default="Qwen/Qwen3-Embedding-0.6B")
    parser.add_argument("--qwen-online", action="store_true", help="Allow downloading/loading Qwen model files from HuggingFace")
    parser.add_argument("--deepseek-model", default="deepseek-chat")
    parser.add_argument("--deepseek-cache", default="data/deepseek_cache.json")
    parser.add_argument("--preference-path", default="data/preference_from_realistic_samples.json")
    parser.add_argument("--out", default="data/semantic_compare_predictions.csv")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    rows = load_rows(args.csv, args.limit)

    preference = PreferenceScorer(start_worker=False, persistence_path=args.preference_path)
    if not os.path.exists(args.preference_path):
        preference.fit_from_csv(args.csv)
    rule = RuleScorer() if args.rule_weight > 0 else None

    all_details = []

    if args.semantic in {"embedding", "both"}:
        embedding = SemanticScorer(cache_path="data/scene_vectors.npy")
        metrics, details = evaluate(
            rows,
            embedding,
            preference,
            args.semantic_weight,
            rule_scorer=rule,
            rule_weight=args.rule_weight,
            preference_weight=args.preference_weight,
            adaptive_semantic=args.adaptive_semantic,
            min_semantic_margin=args.min_semantic_margin,
        )
        print_metrics("Embedding semantic channel", metrics)
        for item in details:
            item["method"] = "embedding"
        all_details.extend(details)

    if args.semantic == "qwen3":
        qwen3 = Qwen3SemanticScorer(
            model_name=args.qwen_model,
            instruction_variant=args.qwen_instruction,
            local_files_only=not args.qwen_online,
        )
        metrics, details = evaluate(
            rows,
            qwen3,
            preference,
            args.semantic_weight,
            rule_scorer=rule,
            rule_weight=args.rule_weight,
            preference_weight=args.preference_weight,
            adaptive_semantic=args.adaptive_semantic,
            min_semantic_margin=args.min_semantic_margin,
        )
        print_metrics("Qwen3 instruction embedding semantic channel", metrics)
        for item in details:
            item["method"] = "qwen3"
        all_details.extend(details)

    if args.semantic == "embedding-proto":
        proto = PrototypeSemanticScorer(
            cache_path="data/minilm_prototype_scene_vectors.npy",
            aggregate=args.prototype_aggregate,
        )
        metrics, details = evaluate(
            rows,
            proto,
            preference,
            args.semantic_weight,
            rule_scorer=rule,
            rule_weight=args.rule_weight,
            preference_weight=args.preference_weight,
            adaptive_semantic=args.adaptive_semantic,
            min_semantic_margin=args.min_semantic_margin,
        )
        print_metrics("MiniLM prototype embedding semantic channel", metrics)
        for item in details:
            item["method"] = "embedding-proto"
        all_details.extend(details)

    if args.semantic == "qwen3-proto":
        qwen3_proto = Qwen3PrototypeSemanticScorer(
            model_name=args.qwen_model,
            cache_path=f"data/{args.qwen_model.replace('/', '_')}_prototype_scene_vectors.npy",
            aggregate=args.prototype_aggregate,
            instruction_variant=args.qwen_instruction,
            local_files_only=not args.qwen_online,
        )
        metrics, details = evaluate(
            rows,
            qwen3_proto,
            preference,
            args.semantic_weight,
            rule_scorer=rule,
            rule_weight=args.rule_weight,
            preference_weight=args.preference_weight,
            adaptive_semantic=args.adaptive_semantic,
            min_semantic_margin=args.min_semantic_margin,
        )
        print_metrics("Qwen3 prototype instruction embedding semantic channel", metrics)
        for item in details:
            item["method"] = "qwen3-proto"
        all_details.extend(details)

    if args.semantic in {"deepseek", "both"}:
        if not os.environ.get("DEEPSEEK_API_KEY"):
            print("\n跳过 DeepSeek：未设置 DEEPSEEK_API_KEY。")
            print("设置方式：export DEEPSEEK_API_KEY='your-key'")
        else:
            deepseek = DeepSeekScorer(
                model=args.deepseek_model,
                cache_path=args.deepseek_cache,
                verbose=args.verbose,
            )
            metrics, details = evaluate(
                rows,
                deepseek,
                preference,
                args.semantic_weight,
                rule_scorer=rule,
                rule_weight=args.rule_weight,
                preference_weight=args.preference_weight,
                adaptive_semantic=args.adaptive_semantic,
                min_semantic_margin=args.min_semantic_margin,
            )
            print_metrics("DeepSeek semantic channel", metrics)
            for item in details:
                item["method"] = "deepseek"
            all_details.extend(details)

    save_details(args.out, all_details)
    if all_details:
        print(f"\n明细已保存: {args.out}")


if __name__ == "__main__":
    main()
