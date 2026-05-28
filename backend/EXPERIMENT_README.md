# 音乐场景推荐实验说明

这个实验包用于验证音乐场景推荐算法在两种数据条件下的表现：

1. **完整模拟数据**：假设时间、地点、运动、心率、环境、日历、App 行为等字段都比较完整。
2. **Sparse 缺失/噪声数据**：更接近真实线上情况，例如 App 行为和日历很难拿到，健康数据依赖授权，地点类型可能有映射噪声。

当前目标不是证明线上准确率，而是验证：

- 数据字段缺失后，算法效果会如何变化；
- missing-aware 规则兜底是否有帮助；
- MiniLM / Qwen3 / DeepSeek 等语义通道在 sparse 场景下是否有增益；
- 个性化偏好分是否能结合用户历史反馈改善排序。

## 目录结构

```text
.
├── generate_samples.py                  # 生成完整模拟数据
├── simulate_real_world_missingness.py    # 生成缺失/噪声版 sparse 数据
├── compare_semantic_methods.py           # 对比不同语义通道的推荐效果
├── rule_scorer.py                        # missing-aware 规则兜底
├── preference_scorer.py                  # 个性化偏好分
├── history_booster.py                    # 稳定版长期习惯分桶回退
├── semantic_scorer.py                    # MiniLM embedding 语义通道
├── qwen3_semantic_scorer.py              # Qwen3 instruction-aware embedding
├── prototype_semantic_scorer.py          # 多 prototype embedding 语义通道
├── scene_prototypes.py                   # 每个场景的多原型描述
├── scenes.py                             # 18 个音乐场景定义
├── hierarchy.py                          # 粗场景分层定义
├── evaluate_hierarchical_recommender.py  # 分层推荐评估
├── optimize_fusion_weights.py            # 融合权重搜索
├── analyze_field_relationships.py        # 字段相关性分析
├── generate_longitudinal_habit_dataset.py # 生成长期习惯学习数据
├── evaluate_longitudinal_habits.py        # 评估长期习惯学习是否有效
├── evaluate_longitudinal_main_algorithm.py # 长期数据上的主算法评估
└── data/
    ├── realistic_scene_samples.csv
    ├── realistic_scene_samples_sparse.csv
    └── preference_from_sparse_samples.json
```

## 18 个细场景

```text
放松、图书馆、健身、通勤、游戏、专注、阅读、深睡眠、减压、
婴儿安睡、胎教、宠物陪伴、经期舒缓、睡午觉、跑步、瑜伽、冥想、深夜EMO
```

## 核心思路

当前推荐分数由三类信号融合：

```text
final_score =
  rule_weight * missing_aware_rule_score
+ semantic_weight * semantic_score
+ preference_weight * preference_score
```

当前 sparse 数据推荐权重：

```text
rule_weight = 0.60
semantic_weight = 0.25
preference_weight = 0.15
```

其中：

- `rule_score`：低权限、可解释、可 fallback 的规则兜底。
- `semantic_score`：MiniLM / Qwen3 / DeepSeek 等语义匹配分。
- `preference_score`：基于用户历史反馈学习，包括停留时长、用户纠错、后续行为、多日一致性等。

## 环境依赖

建议使用 Python 3.10+。

基础依赖：

```bash
pip install numpy pandas scipy scikit-learn sentence-transformers requests
```

Qwen3 embedding 会从 HuggingFace 下载模型。第一次运行可能比较慢。

如果 HuggingFace 下载较慢，可以设置 `HF_TOKEN`：

```bash
export HF_TOKEN="your_huggingface_token"
```

DeepSeek 需要 API key：

```bash
export DEEPSEEK_API_KEY="your_deepseek_api_key"
```

注意：不要把 API key 或 HF token 写进代码。

## 推荐运行顺序

### 1. 生成完整模拟数据

```bash
python3 generate_samples.py
```

输出：

```text
data/realistic_scene_samples.csv
data/realistic_scene_samples.json
```

### 2. 生成缺失/噪声版 sparse 数据

```bash
python3 simulate_real_world_missingness.py
```

输出：

```text
data/realistic_scene_samples_sparse.csv
data/missingness_report.txt
```

当前 sparse 设置大致模拟：

```text
app_event 可用：约 12%
calendar 可用：约 13%
activity_state 可用：约 61%
heart_rate 可用：约 54%
sleep 可用：约 45%
place_type 大部分有，但约 32% 会被打噪或降级
```

### 3. 跑 MiniLM prototype embedding

MiniLM 是当前轻量 baseline embedding，可以本地全量跑：

```bash
python3 compare_semantic_methods.py \
  --semantic embedding-proto \
  --csv data/realistic_scene_samples_sparse.csv \
  --rule-weight 0.60 \
  --semantic-weight 0.25 \
  --preference-weight 0.15 \
  --limit 0
```

### 4. 跑 Qwen3 prototype embedding

Qwen3 是 instruction-aware embedding。建议先跑 30 条：

```bash
python3 compare_semantic_methods.py \
  --semantic qwen3-proto \
  --prototype-aggregate max \
  --qwen-instruction retrieval \
  --csv data/realistic_scene_samples_sparse.csv \
  --rule-weight 0.60 \
  --semantic-weight 0.25 \
  --preference-weight 0.15 \
  --limit 30
```

默认使用：

```text
Qwen/Qwen3-Embedding-0.6B
```

如果要尝试 4B：

```bash
python3 compare_semantic_methods.py \
  --semantic qwen3-proto \
  --qwen-model Qwen/Qwen3-Embedding-4B \
  --qwen-online \
  --prototype-aggregate max \
  --qwen-instruction retrieval \
  --csv data/realistic_scene_samples_sparse.csv \
  --rule-weight 0.60 \
  --semantic-weight 0.25 \
  --preference-weight 0.15 \
  --limit 5
```

注意：4B 在 Mac MPS 上可能内存不足，建议先用 0.6B。

### 5. 跑 DeepSeek LLM 对比

需要先设置：

```bash
export DEEPSEEK_API_KEY="your_deepseek_api_key"
```

然后运行：

```bash
python3 compare_semantic_methods.py \
  --semantic deepseek \
  --csv data/realistic_scene_samples_sparse.csv \
  --rule-weight 0.60 \
  --semantic-weight 0.25 \
  --preference-weight 0.15 \
  --limit 30
```

DeepSeek 有 API 成本和延迟，建议先小样本测试。

## 长期习惯学习数据

如果目标是验证算法是否能学到“同一个用户的长期习惯”，建议使用：

```bash
python3 generate_longitudinal_habit_dataset.py
```

输出：

```text
data/longitudinal_habit_scene_samples.csv
data/longitudinal_habit_scene_samples.json
data/longitudinal_habit_report.json
```

这版数据特点：

```text
用户数：32
周期：120天
每个用户历史：约379-417条session
训练集：前90天
测试集：后30天
```

最新版本还加入了三个更贴近真实线上验证的问题：

- App 必须联网才能打开，因此 `network` 不再生成“无网络/飞行模式”，只保留 `wifi`、`蜂窝数据`、`蜂窝数据（弱）`。
- 每个用户有一周 `disruption week`，用于模拟“长期习惯很稳定，但某一周因为出差、考试、作息变化等原因不按往常习惯发生”的边界情况。
- `event_type` 不再全是 `listen`，而是包含 `impression`、`listen`、`like`、`dislike`、`correction`，更像真实 App 事件日志。

字段设计参考了 Yambda、Deezer、MLHD 和 PIMP 的长期用户日志思路：

- 保留 timestamp、user_id、event_type、played_ratio、liked/disliked、organic/recommendation 等可记录行为。
- 保留当前可观测上下文：时间、地点类型及置信度、运动/心率授权状态、环境、连接等。
- 保留预测时可由 App 历史计算出来的长期偏好特征，例如 `bucket_top_scene_before` 和 `bucket_top_scene_ratio_before`。
- `ground_truth` 只用于离线评测，不作为线上可获取字段。

评估长期习惯学习：

```bash
python3 evaluate_longitudinal_habits.py
```

当前观察结果：

```text
rule only:
Top-1: 0.359
Top-3: 0.548

rule + explicit long-term history features:
Top-1: 0.420
Top-3: 0.644

rule + stable hierarchical history booster:
Top-1: 0.415
Top-3: 0.660

rule + recent 7d history features:
Top-1: 0.344
Top-3: 0.560

rule + PreferenceScorer trained on first 90 days:
Top-1: 0.389
Top-3: 0.597
```

这个结果说明：在长期时序数据上，显式加入用户长期习惯特征后，模型能明显提升；稳定版分桶回退在 Top-1 接近显式 long-term feature 的同时，Top-3 更高，说明它更适合作为候选召回增强；同时 recent 7d 特征在习惯中断期不一定更好，说明数据可以用于检验“长期习惯 vs 最近异常”的边界。

### 长期数据上的主算法评估

主算法形式：

```text
final_score =
  0.60 * rule_score
+ 0.25 * semantic_score
+ 0.15 * preference_score
```

其中 preference 只用前 90 天训练，在后 30 天测试。

运行 MiniLM prototype：

```bash
python3 evaluate_longitudinal_main_algorithm.py \
  --semantic embedding-proto \
  --prototype-aggregate max \
  --limit 0
```

如需把稳定版长期习惯通道也接入主算法，可以显式加入：

```bash
python3 evaluate_longitudinal_main_algorithm.py \
  --semantic embedding-proto \
  --prototype-aggregate max \
  --rule-weight 0.54 \
  --semantic-weight 0.23 \
  --preference-weight 0.13 \
  --stable-history-weight 0.10 \
  --limit 120
```

当前全量测试结果：

```text
semantic=embedding-proto
test=3167
semantic Top-1: 0.077
semantic Top-3: 0.290
fused Top-1:    0.376
fused Top-3:    0.597
```

运行 Qwen3 prototype，小样本先测：

```bash
python3 evaluate_longitudinal_main_algorithm.py \
  --semantic qwen3-proto \
  --prototype-aggregate max \
  --qwen-instruction retrieval \
  --limit 30
```

当前同一批 30 条样本对比：

```text
MiniLM prototype:
semantic Top-1: 0.033
semantic Top-3: 0.167
fused Top-1:    0.567
fused Top-3:    0.767

Qwen3 prototype:
semantic Top-1: 0.167
semantic Top-3: 0.233
fused Top-1:    0.600
fused Top-3:    0.767
```

这说明在长期数据的小样本测试中，Qwen3 的语义召回比 MiniLM 更强，但最终融合仍主要依赖 rule + preference。

## 指标解释

脚本会输出类似：

```text
semantic Top-1
semantic Top-3
fused Top-1
fused Top-3
avg latency
```

含义：

- `semantic Top-1`：只看语义通道，Top-1 是否命中 ground truth。
- `semantic Top-3`：只看语义通道，ground truth 是否进入前三。
- `fused Top-1`：规则 + 语义 + 偏好融合后，Top-1 是否命中。
- `fused Top-3`：融合后，ground truth 是否进入前三。
- `avg latency`：平均每条样本的语义通道耗时。命中 cache 时会偏低。

## 当前观察结论

完整字段数据上的结果更像理想上限；真实 sparse 数据下效果会明显下降。

当前 sparse 数据实验观察：

- `app_event` 和 `calendar` 可用性低，不能作为主链路依赖。
- `place_type` 存在噪声，需要置信度和降权。
- `activity_state` 和 `heart_rate` 依赖健康授权，且用户刚打开 App 时心率可能滞后。
- `missing-aware rule` 对 sparse 场景非常重要。
- `MiniLM/Qwen3 embedding` 更适合做语义召回辅助，不适合单独承担 18 场景精排。
- `Qwen3 instruction` 不宜太长，短检索式 instruction 更适合 embedding。
- 多 prototype 描述比单条场景描述更稳。

## 注意事项

1. 当前数据是模拟数据，不代表线上真实准确率。
2. `Top-1 / Top-3` 结果受样本量、随机种子、缺失率设置影响。
3. Qwen3 第一次运行会下载模型。
4. DeepSeek 需要 API key，且会产生调用成本。
5. 不要提交或分享任何 API key / HF token。
