"""评估 flat 推荐 vs 分层推荐。

分层逻辑:
  1. 先融合 rule / semantic / preference 得到18个细场景分。
  2. 把细场景分聚合成粗场景分。
  3. 只在Top-N粗场景覆盖的候选子集中排序细场景。

示例:
  # sparse + embedding
  python3 evaluate_hierarchical_recommender.py --semantic embedding --limit 0

  # sparse + DeepSeek，建议先小样本
  export DEEPSEEK_API_KEY="your-key"
  python3 evaluate_hierarchical_recommender.py --semantic deepseek --limit 30
"""

import argparse
import csv
import os
import time
from typing import Dict, List, Tuple

from hierarchy import SCENE_GROUPS, group_for_scene, scenes_for_groups
from hierarchical_llm_scorer import DeepSeekHierarchicalScorer
from llm_scorer import DeepSeekScorer
from preference_scorer import PreferenceScorer
from prototype_semantic_scorer import PrototypeSemanticScorer, Qwen3PrototypeSemanticScorer
from qwen3_semantic_scorer import Qwen3SemanticScorer
from rule_scorer import RuleScorer
from scenes import SCENE_NAMES
from semantic_scorer import SemanticScorer


def load_rows(path: str, limit: int) -> List[Dict]:
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    return rows[:limit] if limit and limit > 0 else rows


def normalize(scores: Dict[str, float]) -> Dict[str, float]:
    values = list(scores.values())
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return {k: 0.5 for k in scores}
    return {k: (v - lo) / (hi - lo) for k, v in scores.items()}


def fuse(rule_scores, semantic_scores, preference_scores, weights):
    wr, ws, wp = weights
    rule = normalize(rule_scores)
    semantic = normalize(semantic_scores)
    preference = normalize(preference_scores)
    return {
        scene: (
            wr * rule.get(scene, 0.5)
            + ws * semantic.get(scene, 0.5)
            + wp * preference.get(scene, 0.5)
        )
        for scene in SCENE_NAMES
    }


def aggregate_group_scores(scene_scores: Dict[str, float]) -> Dict[str, float]:
    group_scores = {}
    for group, scenes in SCENE_GROUPS.items():
        values = sorted([scene_scores[s] for s in scenes], reverse=True)
        top = values[0]
        mean = sum(values) / len(values)
        top2_mean = sum(values[:2]) / min(2, len(values))
        # top值保留“强证据”，均值避免大组靠单个误分过强。
        group_scores[group] = 0.60 * top + 0.25 * top2_mean + 0.15 * mean
    return group_scores


def flat_rank(scene_scores: Dict[str, float]) -> List[str]:
    return sorted(scene_scores, key=scene_scores.get, reverse=True)


def hierarchical_rank(scene_scores: Dict[str, float], top_groups: int, group_boost: float) -> Tuple[List[str], List[str], Dict[str, float]]:
    group_scores = aggregate_group_scores(scene_scores)
    ranked_groups = sorted(group_scores, key=group_scores.get, reverse=True)
    active_groups = ranked_groups[:top_groups]
    candidates = scenes_for_groups(active_groups)

    boosted = {}
    for scene in candidates:
        group = group_for_scene(scene)
        boosted[scene] = scene_scores[scene] + group_boost * group_scores[group]
    ranked_scenes = sorted(boosted, key=boosted.get, reverse=True)
    return ranked_scenes, ranked_groups, group_scores


def evaluate(rows, semantic_scorer, preference_scorer, weights, top_groups, group_boost):
    rule_scorer = RuleScorer()
    counters = {
        "flat_top1": 0,
        "flat_top3": 0,
        "hier_top1": 0,
        "hier_top3": 0,
        "group_top1": 0,
        "group_top2": 0,
    }
    by_scene = {scene: {"n": 0, "flat_top1": 0, "hier_top1": 0, "hier_top3": 0} for scene in SCENE_NAMES}
    details = []
    latency = 0.0

    for row in rows:
        gt = row["ground_truth"]
        gt_group = group_for_scene(gt)
        start = time.time()
        semantic_scores = semantic_scorer.score_all(row)
        latency += time.time() - start
        scene_scores = fuse(
            rule_scorer.score_all(row),
            semantic_scores,
            preference_scorer.score_all(row),
            weights,
        )

        flat = flat_rank(scene_scores)
        hier, groups, group_scores = hierarchical_rank(scene_scores, top_groups, group_boost)

        counters["flat_top1"] += int(flat[0] == gt)
        counters["flat_top3"] += int(gt in flat[:3])
        counters["hier_top1"] += int(hier[0] == gt)
        counters["hier_top3"] += int(gt in hier[:3])
        counters["group_top1"] += int(groups[0] == gt_group)
        counters["group_top2"] += int(gt_group in groups[:2])

        by_scene[gt]["n"] += 1
        by_scene[gt]["flat_top1"] += int(flat[0] == gt)
        by_scene[gt]["hier_top1"] += int(hier[0] == gt)
        by_scene[gt]["hier_top3"] += int(gt in hier[:3])

        details.append({
            "sample_id": row.get("sample_id", ""),
            "ground_truth": gt,
            "ground_truth_group": gt_group,
            "group_top1": groups[0],
            "group_top2": "|".join(groups[:2]),
            "flat_top1": flat[0],
            "flat_top3": "|".join(flat[:3]),
            "hier_top1": hier[0],
            "hier_top3": "|".join(hier[:3]),
            "signal_availability_profile": row.get("signal_availability_profile", ""),
            "place_type_quality": row.get("place_type_quality", ""),
        })

    n = len(rows)
    metrics = {k: v / n if n else 0.0 for k, v in counters.items()}
    metrics["samples"] = n
    metrics["avg_semantic_latency_ms"] = 1000 * latency / n if n else 0.0
    return metrics, by_scene, details


def save_details(path: str, details: List[Dict]):
    if not details:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(details[0].keys()))
        writer.writeheader()
        writer.writerows(details)


def print_metrics(title: str, metrics: Dict, by_scene: Dict):
    print(f"\n{title}")
    print("-" * len(title))
    print(f"samples:       {metrics['samples']}")
    print(f"group Top-1:   {metrics['group_top1']:.3f}")
    print(f"group Top-2:   {metrics['group_top2']:.3f}")
    print(f"flat Top-1:    {metrics['flat_top1']:.3f}")
    print(f"flat Top-3:    {metrics['flat_top3']:.3f}")
    print(f"hier Top-1:    {metrics['hier_top1']:.3f}")
    print(f"hier Top-3:    {metrics['hier_top3']:.3f}")
    print(f"avg latency:   {metrics['avg_semantic_latency_ms']:.0f} ms/sample")

    worst = []
    for scene, item in by_scene.items():
        if item["n"]:
            worst.append((
                item["hier_top1"] / item["n"],
                item["hier_top3"] / item["n"],
                scene,
                item["n"],
            ))
    print("\nWorst scenes by hierarchical Top-1:")
    for top1, top3, scene, n in sorted(worst)[:8]:
        print(f"  {scene:6s} n={n:2d} Top-1={top1:.2f} Top-3={top3:.2f}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default="data/realistic_scene_samples_sparse.csv")
    parser.add_argument("--semantic", choices=["embedding", "embedding-proto", "qwen3", "qwen3-proto", "deepseek", "deepseek-hier"], default="embedding")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--rule-weight", type=float, default=0.60)
    parser.add_argument("--semantic-weight", type=float, default=0.25)
    parser.add_argument("--preference-weight", type=float, default=0.15)
    parser.add_argument("--top-groups", type=int, default=2)
    parser.add_argument("--group-boost", type=float, default=0.20)
    parser.add_argument("--preference-path", default="data/preference_from_sparse_samples.json")
    parser.add_argument("--deepseek-cache", default="data/deepseek_sparse_cache.json")
    parser.add_argument("--deepseek-model", default="deepseek-chat")
    parser.add_argument("--out", default="data/hierarchical_predictions.csv")
    parser.add_argument("--qwen-instruction", default="short")
    parser.add_argument("--qwen-model", default="Qwen/Qwen3-Embedding-0.6B")
    parser.add_argument("--qwen-online", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    rows = load_rows(args.csv, args.limit)
    preference = PreferenceScorer(start_worker=False, persistence_path=args.preference_path)
    if not os.path.exists(args.preference_path):
        preference.fit_from_csv(args.csv)

    if args.semantic == "embedding":
        semantic = SemanticScorer(cache_path="data/scene_vectors.npy")
    elif args.semantic == "embedding-proto":
        semantic = PrototypeSemanticScorer(cache_path="data/minilm_prototype_scene_vectors.npy")
    elif args.semantic == "qwen3":
        semantic = Qwen3SemanticScorer(
            model_name=args.qwen_model,
            instruction_variant=args.qwen_instruction,
            local_files_only=not args.qwen_online,
        )
    elif args.semantic == "qwen3-proto":
        semantic = Qwen3PrototypeSemanticScorer(
            model_name=args.qwen_model,
            cache_path=f"data/{args.qwen_model.replace('/', '_')}_prototype_scene_vectors.npy",
            instruction_variant=args.qwen_instruction,
            local_files_only=not args.qwen_online,
        )
    elif args.semantic == "deepseek":
        if not os.environ.get("DEEPSEEK_API_KEY"):
            print("未设置 DEEPSEEK_API_KEY，无法跑 DeepSeek。")
            print("设置方式：export DEEPSEEK_API_KEY='your-key'")
            return
        semantic = DeepSeekScorer(
            model=args.deepseek_model,
            cache_path=args.deepseek_cache,
            verbose=args.verbose,
        )
    else:
        if not os.environ.get("DEEPSEEK_API_KEY"):
            print("未设置 DEEPSEEK_API_KEY，无法跑 DeepSeek 分层方案。")
            print("设置方式：export DEEPSEEK_API_KEY='your-key'")
            return
        semantic = DeepSeekHierarchicalScorer(
            model=args.deepseek_model,
            cache_path=args.deepseek_cache,
            top_groups=args.top_groups,
            verbose=args.verbose,
        )

    weights = (args.rule_weight, args.semantic_weight, args.preference_weight)
    metrics, by_scene, details = evaluate(rows, semantic, preference, weights, args.top_groups, args.group_boost)
    title = f"Hierarchical sparse evaluation ({args.semantic})"
    print_metrics(title, metrics, by_scene)
    save_details(args.out, details)
    print(f"\n明细已保存: {args.out}")


if __name__ == "__main__":
    main()
