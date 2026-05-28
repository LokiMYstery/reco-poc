"""Qwen3 instruction-aware embedding semantic scorer."""

from semantic_scorer import SemanticScorer


QWEN3_RECOMMENDATION_INSTRUCTION = (
    "Instruct: 根据手机、可穿戴、环境、连接、日历和用户反馈等可观测信号，"
    "为音乐场景推荐检索最相关的候选场景。"
    "注意 app_event 和 calendar 可能缺失，place_type 可能有噪声，"
    "heart_rate 在用户刚打开App时可能滞后；缺失字段不能当作负证据。"
    "重点区分：专注/阅读/图书馆，健身/跑步/瑜伽，"
    "深睡眠/睡午觉/婴儿安睡，放松/减压/冥想/深夜EMO/经期舒缓。"
    "\nQuery: "
)


QWEN3_INSTRUCTION_VARIANTS = {
    "long": QWEN3_RECOMMENDATION_INSTRUCTION,
    "short": (
        "Instruct: 根据用户当前可观测上下文，检索最匹配的音乐推荐场景。\n"
        "Query: "
    ),
    "retrieval": (
        "Instruct: Given observable user context, retrieve the most relevant music listening scenario.\n"
        "Query: "
    ),
    "sparse": (
        "Instruct: 检索适合当前稀疏上下文的音乐场景。缺失字段忽略，低置信字段只作弱证据。\n"
        "Query: "
    ),
    "none": "",
}


class Qwen3SemanticScorer(SemanticScorer):
    def __init__(
        self,
        model_name: str = "Qwen/Qwen3-Embedding-0.6B",
        cache_path: str = "data/qwen3_scene_vectors_v2.npy",
        use_cache: bool = True,
        instruction_variant: str = "short",
        local_files_only: bool = True,
    ):
        query_instruction = QWEN3_INSTRUCTION_VARIANTS.get(instruction_variant, instruction_variant)
        super().__init__(
            model_name=model_name,
            cache_path=cache_path,
            use_cache=use_cache,
            query_instruction=query_instruction,
            document_instruction=None,
            local_files_only=local_files_only,
        )
