# 音乐场景推荐主算法汇报文档

## 1. 项目目标

本项目目标是验证：在手机 App / 手表 / 系统能力真实可获取的数据条件下，是否可以对用户当前音乐使用场景进行推荐。

这里的“场景推荐”不是直接识别用户正在做什么，而是基于可观测上下文和历史反馈，推荐一个更适合当前时刻的音乐场景，例如：

```text
放松、图书馆、健身、通勤、游戏、专注、阅读、深睡眠、减压、
婴儿安睡、胎教、宠物陪伴、经期舒缓、睡午觉、跑步、瑜伽、冥想、深夜EMO
```

核心约束：

- 线上输入不能直接使用“用户正在跑步 / 正在学习 / 正在哄娃”这类不可直接获取标签。
- 只能使用真实可获取或可授权获取的 raw context，例如时间、位置、运动状态、心率、噪音、光线、天气、蓝牙、网络、日历、自家 App 内行为和历史反馈。
- 权限缺失是常态，所以算法必须 missing-aware，即字段缺失时不把缺失当作负证据。
- 离线数据里的 `ground_truth` 只用于评测，线上不会使用。

## 2. 可用数据与处理原则

当前假设可以使用的数据分为四类。

### 2.1 低权限稳定信号

这类信号通常比较稳定，适合作为推荐主干：

| 信号 | 示例 | 作用 |
|---|---|---|
| 时间 | hour、weekday、date_type、time_slot | 睡眠、午睡、通勤、专注等主干判断 |
| 网络 | wifi、蜂窝数据、蜂窝数据（弱） | App 可用性、在途弱信号 |
| 蓝牙连接 | 耳机、车载蓝牙、家用音响 | 通勤、运动、睡眠、家庭场景辅助 |
| 自家 App 行为 | impression、listen、like、dislike、correction | 个性化学习核心 |

### 2.2 中等权限或不稳定信号

这类信号有用，但不能硬依赖：

| 信号 | 风险 | 处理方式 |
|---|---|---|
| place_type | POI 映射可能不准 | 使用 `place_type_confidence` 降权 |
| 天气 | 影响有限 | 作为户外/跑步/通勤弱信号 |
| 光线 | 部分设备/API 不稳定 | 作为睡眠/午睡/深夜辅助 |
| 噪音 | 麦克风权限和隐私风险 | 只使用 dBA 统计值，不上传音频 |

### 2.3 高权限健康信号

这类信号区分度强，但授权率可能有限：

| 信号 | 示例 | 处理方式 |
|---|---|---|
| activity_state | 静止、慢速、中速、高速 | 有则强加分，缺失不扣分 |
| heart_rate_zone | 静息、稍高、高、波动 | 只加分，不作为运动必要条件 |
| sleep / workout | 睡眠、健身记录 | 作为强辅助信号 |
| steps | 最近 10 分钟步数 | 辅助判断运动/通勤 |

特别注意：用户打开 App 推荐音乐时，可能还没有真正开始运动，所以心率不一定已经升高。因此心率只能作为增强信号，不能作为运动场景的硬条件。

### 2.4 高稀疏增强信号

| 信号 | 问题 | 定位 |
|---|---|---|
| 日历 | 权限大，很多人不用日历 | 有则增强，无则忽略 |
| 外部 app_event | 很可能拿不到 | 不作为主链路 |
| 用户问卷 | 冷启动有效，但有偏差 | 作为 profile prior |
| 用户纠错 | 数据少但价值高 | 强反馈信号 |

## 3. 数据生成与评估数据集

为了验证算法逻辑，目前构造了三类离线数据。

### 3.1 完整模拟数据

脚本：

```bash
python3 generate_samples.py
```

输出：

```text
data/realistic_scene_samples.csv
data/realistic_scene_samples.json
```

这版数据用于验证算法在理想字段完整情况下是否能跑通。

### 3.2 Sparse 缺失/噪声数据

脚本：

```bash
python3 simulate_real_world_missingness.py
```

输出：

```text
data/realistic_scene_samples_sparse.csv
```

这版数据更接近真实线上情况：

```text
app_event 可用：约 12%
calendar 可用：约 13%
activity_state 可用：约 61%
heart_rate 可用：约 54%
sleep 可用：约 45%
place_type 大部分有，但约 32% 会被打噪或降级
```

### 3.3 长期习惯数据

脚本：

```bash
python3 generate_longitudinal_habit_dataset.py
```

输出：

```text
data/longitudinal_habit_scene_samples.csv
data/longitudinal_habit_scene_samples.json
data/longitudinal_habit_report.json
```

特点：

```text
用户数：32
周期：120 天
训练集：前 90 天
测试集：后 30 天
每个用户每天 2-5 个 session
event_type 包括 impression / listen / like / dislike / correction
每个用户设置一周 disruption week，用于模拟习惯中断
```

长期数据主要用于验证：算法是否能学会“同一个用户在某些时间段/上下文里的长期偏好”，以及是否会被最近一周异常行为带偏。

## 4. 主算法架构

当前主算法由四类信号组成：

```text
final_score =
  rule_weight * rule_score
+ semantic_weight * semantic_score
+ preference_weight * preference_score
+ history_weight * stable_history_score
```

其中 `history_weight` 是可选项。原始三通道版本中只包含 rule、semantic、preference；最新版本加入了稳定版长期历史回退通道，用于增强候选召回稳定性。

推荐流程：

```text
Raw Context
  ↓
字段清洗与标签映射
  ↓
Rule Scorer
Semantic Scorer
Preference Scorer
Stable History Booster
  ↓
加权融合
  ↓
Top-K 场景推荐
```

## 5. Rule Scorer：missing-aware 规则兜底

文件：

```text
rule_scorer.py
```

Rule Scorer 的定位是低权限、可解释、可 fallback 的基线通道。

设计原则：

- 时间是主干信号。
- 地点只按置信度加分，不做硬判断。
- 运动和心率有则加分，缺失不扣分。
- 日历和 App 行为是增强信号，不作为主链路。
- 对易混淆场景做组合判断，例如：
  - 跑步 vs 健身
  - 专注 vs 阅读 vs 图书馆
  - 深睡眠 vs 睡午觉 vs 深夜EMO
  - 放松 vs 冥想 vs 减压

例子：

```text
车载蓝牙 + 早晚高峰 + 蜂窝数据 -> 通勤加分
高速运动 + 步数高 -> 跑步加分
静止 + 安静 + 白天办公时间 -> 专注/阅读/图书馆加分
深夜 + 暗光 + 静止 -> 深睡眠/深夜EMO加分
心率波动 + 静止 -> 减压/深夜EMO加分
```

Rule Scorer 不追求单独达到最高准确率，它的价值是：

- 在字段缺失时提供稳定兜底。
- 让推荐结果可解释。
- 限制 semantic / preference 在噪声场景下跑偏。

## 6. Semantic Scorer：语义召回通道

语义通道用于把当前上下文文本和场景描述做语义匹配。当前支持三类方案。

### 6.1 MiniLM embedding

文件：

```text
semantic_scorer.py
prototype_semantic_scorer.py
```

优点：

- 本地运行。
- 延迟低。
- 成本低。

缺点：

- 对中文短上下文和细粒度音乐场景的理解有限。
- 在 sparse 数据上单独 semantic Top-1 不高。

### 6.2 Qwen3 instruction-aware embedding

文件：

```text
qwen3_semantic_scorer.py
prototype_semantic_scorer.py
```

优点：

- 支持 instruction-aware retrieval。
- 小样本上语义召回好于 MiniLM。

当前建议：

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

注意：

- 本地 0.6B 可以跑。
- 4B 在 Mac MPS 上可能内存不足。
- instruction 不宜太复杂，否则可能偏离 embedding 模型训练分布。

### 6.3 DeepSeek LLM

文件：

```text
llm_scorer.py
hierarchical_llm_scorer.py
```

优点：

- 对复杂文本和缺失上下文有更强推理能力。

缺点：

- 有 API 成本。
- 有延迟。
- 线上实时推荐需要缓存、降级和限流。

当前定位更适合：

- 离线评估。
- 生成场景解释。
- 做小样本对比或冷启动 fallback。

## 7. Preference Scorer：个性化偏好分

文件：

```text
preference_scorer.py
```

Preference Scorer 的目标不是猜当前场景，而是学习：

```text
用户在某类上下文下，最终更愿意接受哪个音乐场景。
```

输入反馈包括：

```text
dwell_time_sec
played_ratio_pct
like / dislike
next_action
user_correction_from
user_correction_to
multiday_consistency
```

反馈解释：

```text
长停留 + 高播放完成率 -> 正反馈
收藏 / 继续播放 -> 强正反馈
短停留 / 跳过 / 关闭 -> 负反馈
用户主动纠错 from A to B -> A 负反馈，B 强正反馈
多日一致性高 -> 提高训练权重
```

分桶特征：

```text
weekday
hour_bucket
place_type
activity_state
heart_rate_zone
noise_class
bluetooth
```

最新稳定性改动：

- `place_type_confidence` 低时，地点降级为 `任意`。
- `place_type_quality=noisy_mapping` 时，地点不进入细分桶。
- `activity_state_available=0` 时，运动降级为 `任意`。
- `heart_rate_available=0` 时，心率降级为 `任意`。
- 缺失字段不作为负证据。

## 8. Stable History Booster：稳定版长期习惯回退

文件：

```text
history_booster.py
```

这是最新加入的稳定性增强模块。它和 Preference Scorer 不完全相同：

- Preference Scorer 更像在线学习器，吃正负反馈。
- Stable History Booster 更像显式长期习惯召回器，重点处理 bucket 稀疏和回退。

回退层级：

```text
user + weekday + time_slot + activity + place
-> user + weekday + time_slot + activity
-> user + weekday + time_slot
-> user + time_slot
-> user global
-> profile + time_slot cohort
-> global
```

稳定性策略：

- 小样本 bucket 做 shrinkage smoothing。
- 地点低置信时回退到更粗粒度。
- disruption week 样本降权。
- 不让最近一周异常直接覆盖长期习惯。

这个模块的价值是：

- 在真实线上历史稀疏时更稳。
- 对 Top-3 候选召回尤其有帮助。
- 更容易解释为“用户长期习惯增强”，而不是纯规则堆叠。

## 9. 当前评估结果

### 9.1 Sparse 数据主算法结果

在 sparse/噪声数据上，使用：

```text
rule_weight = 0.60
semantic_weight = 0.25
preference_weight = 0.15
```

已有观察：

```text
embedding fused Top-1: 约 0.532
embedding fused Top-3: 约 0.796

LLM / DeepSeek fused Top-1: 约 0.467
LLM / DeepSeek fused Top-3: 约 0.700
```

说明：

- sparse 数据下，rule 兜底仍然重要。
- semantic 单独不一定很高，但融合后有帮助。
- LLM 小样本结果受 prompt、样本选择和 cache 影响，不宜直接当最终线上结论。

### 9.2 长期习惯数据结果

运行：

```bash
python3 evaluate_longitudinal_habits.py
```

结果：

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
Top-1: 0.388
Top-3: 0.590
```

解释：

- `rule only` 是只看当前上下文规则的 baseline。
- `explicit long-term history` 直接使用数据中预测时刻之前的历史聚合特征，Top-1 提升明显。
- `stable hierarchical history booster` Top-1 接近显式 long-term 特征，Top-3 更高，说明稳定回退更适合候选召回。
- `recent 7d` 效果反而下降，说明短期历史容易被 disruption week 带偏。
- `PreferenceScorer` 有提升，但不如显式 history，说明后续可以继续优化偏好学习器。

### 9.3 主算法加稳定历史通道

运行示例：

```bash
python3 evaluate_longitudinal_main_algorithm.py \
  --semantic embedding-proto \
  --rule-weight 0.54 \
  --semantic-weight 0.23 \
  --preference-weight 0.13 \
  --stable-history-weight 0.10 \
  --limit 120
```

抽样 120 条结果：

```text
不加 stable history:
fused Top-1: 0.517
fused Top-3: 0.717

加 stable history:
fused Top-1: 0.533
fused Top-3: 0.733
```

说明：稳定历史通道带来小幅但方向一致的提升，且解释性较好。

## 10. 为什么不只追求模拟数据最高分

当前数据是模拟生成的，虽然尽量参考真实可获取字段，但仍然存在一个风险：

```text
如果数据生成逻辑和 rule scorer 太相似，rule 分数越调越高，可能只是学会了生成器，而不代表线上真实效果。
```

因此当前评估重点不是单纯刷最高 Top-1，而是验证：

- 字段缺失后算法是否还能稳定工作。
- 地点噪声是否会被降权。
- 长期习惯是否能带来增益。
- 最近异常是否会误导推荐。
- semantic / LLM 是否能在规则之外提供补充。

更合理的汇报口径是：

```text
我们已经验证了 missing-aware rule、semantic retrieval、个性化偏好和长期历史回退这几类信号的可行性。
在模拟 sparse 数据和长期习惯数据上，长期历史信号能稳定提升 Top-3 候选质量；
但最终线上效果仍需要真实日志、人工边界 case 和 A/B 测试验证。
```

## 11. 当前算法优势

### 11.1 工程可落地

- 不依赖不可直接获取的“用户正在做什么”标签。
- 对权限缺失有 fallback。
- 可根据用户授权情况分层运行。

### 11.2 可解释

每个推荐结果可以拆成：

```text
规则为什么加分
语义为什么相似
历史上用户是否常在类似上下文选择该场景
用户是否曾纠错或长期停留
```

### 11.3 支持个性化

系统不是只靠通用规则，而是可以从用户历史中学习：

- 某个用户是否习惯晚上跑步。
- 某个用户是否午休时听睡眠类音乐。
- 某个用户是否在通勤时更接受专注/放松而不是通勤场景。
- 某个用户是否长期在某些时间段打开特定场景。

### 11.4 支持真实线上稀疏

已考虑：

- app_event 很少可用。
- calendar 很少可用。
- activity / heart rate 需要授权。
- place_type 可能映射错误。
- 用户刚打开 App 时，心率和运动状态可能尚未体现。
- App 需要联网时，不应生成无网络/飞行模式作为推荐时刻。

## 12. 当前限制

### 12.1 数据仍然是模拟数据

当前结果不能直接等价于线上准确率。它更适合证明算法思路可行，以及比较不同模块的相对贡献。

### 12.2 ground truth 本身可能模糊

某些场景天然相近：

```text
放松 vs 减压 vs 冥想
专注 vs 阅读 vs 图书馆
健身 vs 跑步 vs 瑜伽
深睡眠 vs 睡午觉 vs 婴儿安睡
```

因此 Top-3 在音乐场景推荐中很重要，因为实际产品可以展示候选或根据用户下一步行为继续 rerank。

### 12.3 外部 app_event 和 calendar 不宜作为主链路

这两个字段很有信息量，但真实可用性低。当前算法已经把它们作为增强信号，而不是主信号。

### 12.4 Qwen / LLM 成本和部署需要单独评估

Embedding 可以本地低成本跑，LLM 更适合离线评估、解释生成、小样本 fallback 或云端 rerank。

## 13. 建议下一步

### 13.1 做字段消融实验

建议补充：

```text
只用时间
时间 + 运动 + 心率
时间 + 地点
时间 + 运动 + 心率 + 地点
再加入环境/连接
再加入长期历史
再加入 semantic
```

目的：回答“到底哪些字段真的有贡献”。

### 13.2 做人工边界 case

建议手写 20-50 条真实边界样本，例如：

```text
跑步机刚打开 App，心率还没升高
地点被误判为商场，但蓝牙是车载
平时周三晚上跑步，但这周出差住酒店
在图书馆但戴耳机玩游戏
深夜在住宅区，静止，心率波动，不一定是深睡眠
中午在办公室，静止，低光，可能是午睡也可能是放松
```

目的：确认算法不是只适配模拟生成器。

### 13.3 把权重搜索改成稳定区间

不要只汇报一个最高分，而是汇报稳定范围：

```text
rule_weight: 0.50-0.65
semantic_weight: 0.15-0.30
preference/history_weight: 0.15-0.25
```

这比单点最优更适合工程落地。

### 13.4 收集真实轻量日志

最小可行真实日志可以包括：

```text
timestamp
user_id
session_id
recommended_scene
clicked_scene
dwell_time_sec
played_ratio_pct
skip / like / dislike
bluetooth
network
place_type + confidence
activity_state_available
heart_rate_available
```

不一定一开始就要拿健康权限，先用低权限字段和自家 App 内反馈也可以开始验证长期偏好。

## 14. 可汇报结论

可以这样对外说明：

```text
目前我们完成了一个音乐场景推荐 POC。算法使用 missing-aware rule、embedding/LLM semantic retrieval、个性化偏好分和稳定版长期历史回退进行融合。

数据侧没有直接假设用户正在做什么，而是从真实可获取的 raw context 出发，包括时间、地点类型及置信度、运动/心率授权状态、环境、连接状态、自家 App 行为和历史反馈。

在 sparse/噪声模拟数据上，融合方案可以保持可用效果；在长期习惯数据上，加入长期历史后 Top-3 从 0.548 提升到 0.660，说明用户历史习惯对候选召回有明显帮助。

当前结果主要用于验证算法方向和模块贡献，不直接代表线上准确率。下一步建议补字段消融、人工边界 case 和真实轻量日志验证。
```

