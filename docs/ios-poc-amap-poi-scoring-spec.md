# SPEC: 高德 POI 地点类型打分链路

## Metadata

- Date: 2026-06-02
- Scope: iOS / Swift 前端 PoC 使用高德 Web 服务 POI 推导 `place_candidates` 与 `place_type_*`
- Upstream SPEC: `docs/ios-frontend-poc-spec.md`
- Backend contract: `docs/frontend-backend-payload-contract.md`

## 1. 目标与输出

本方案用高德 Web 服务周边 POI 推导地点上下文。前端只上传脱敏粗地点候选和兼容单值字段，不把 POI 原始名称、地址或高德 ID 上传给后端。

默认上传 `place_candidates` Top-3，同时保留兼容单值字段。`place_candidates` 允许 `0...3` 个候选；有候选时按 confidence 降序上传，0 个候选时可以省略该字段。

```json
{
  "place_candidates": [
    {
      "place_type": "运动场所",
      "confidence": 0.74,
      "distance_m": 32.0,
      "source": "amap_typecode_name",
      "quality": "exact_or_good_mapping"
    }
  ],
  "place_type": "运动场所",
  "place_type_available": 1,
  "place_type_confidence": 0.74,
  "place_type_quality": "exact_or_good_mapping"
}
```

兼容字段 `place_type`、`place_type_available`、`place_type_confidence`、`place_type_quality` 始终随 Top-1 结果一起传。高德返回不足 3 个 POI、无可用 POI、请求失败或 key 缺失时，不能强行补齐候选。

内部地点枚举固定沿用现有后端合同：

```text
任意、住宅区、商场、酒店、餐厅、公园、写字楼、机场、图书馆、海边、户外、在途、高铁站、地铁站、运动场所
```

## 2. 数据获取链路

1. 获取 iOS location best sample：`latitude`、`longitude`、`horizontal_accuracy_m`、timestamp。
2. 如果定位不可用、样本过旧或 `horizontal_accuracy_m > 1000`，跳过高德 POI，输出 unavailable 组合。
3. 将 iOS/CoreLocation 坐标按本地配置处理：
   - 默认 `RECO_AMAP_INPUT_COORDSYS=gps`：先调用高德坐标转换得到高德坐标。
   - 如果实测输入已是高德坐标，可本地配置为 `autonavi`，直接用于 POI 查询。
4. 调用高德 Web 服务周边搜索：
   - URL: `https://restapi.amap.com/v5/place/around`
   - `location=<amap_lon>,<amap_lat>`
   - `radius=500`
   - `sortrule=distance`
   - `page_size=10`
   - `show_fields=business`
   - `types` 使用粗类覆盖餐饮、购物、住宿、商务住宅、科教文化、公司企业、交通设施、风景名胜、体育休闲服务。
5. 解析返回 `pois`，只读取本地决策需要的字段：`name`、`type`、`typecode`、`location`、`distance`。
6. 过滤无坐标、距离不可计算、距离 `> 500m` 的 POI；去重后按候选分排序，保留最多 3 个脱敏候选。
7. 按 `place_type` 聚合同类候选，选出最终 Top-1，生成 `place_type_*`。
8. 高德链路失败时，不阻塞推荐：直接输出 `任意/unavailable`，不启用其它 POI 查询链路。

## 3. POI 候选字段与隐私

本地原始 POI 字段：

| 字段 | 来源 | 用途 | 是否上传 |
|---|---|---|---:|
| `name` | 高德 POI | 关键词辅助打分和冲突判断 | 否 |
| `type` | 高德 POI | 文本 fallback 和诊断归类 | 否 |
| `typecode` | 高德 POI | 主映射依据 | 否 |
| `location` | 高德 POI | 距离计算 | 否 |
| `distance` | 高德 POI | 首选距离来源 | 否 |

可进入 trace 的信息必须脱敏：

- 允许：`place_type`、候选分、距离、typecode 大类或完整 typecode、source、reason code。
- 不允许：真实 API key、完整请求 URL、POI `name` 原文、地址、高德 POI ID。

`place_candidates` 只传脱敏结构：

```json
{
  "place_type": "餐厅",
  "confidence": 0.66,
  "distance_m": 42.0,
  "source": "amap_typecode_name",
  "quality": "noisy_mapping"
}
```

## 4. typecode 主映射

`typecode` 是主证据。实现时使用前缀表和少量精确码表，避免依赖自由文本。

| 高德 typecode / 前缀 | 内部 `place_type` | 置信策略 |
|---|---|---|
| `050000` 餐饮服务 | `餐厅` | 强 |
| `060000` 购物服务 | `商场` | 中强；便利店等小店可降权 |
| `100000` 住宿服务 | `酒店` | 强 |
| `080000` 体育休闲服务 / `0801xx` 运动场馆 | `运动场所` | 强；健身房、体育馆、球场等 name/type 同向时加分 |
| `110100` / 风景名胜中公园类 | `公园` | 强 |
| 图书馆精确类 | `图书馆` | 强 |
| 机场精确类 | `机场` | 强 |
| 地铁站精确类 | `地铁站` | 强 |
| 火车站/高铁站精确类 | `高铁站` | 强 |
| `150000` 交通设施服务但无法细分 | `在途` | 中；需结合 motion/距离 |
| `170000` 公司企业 | `写字楼` | 中强 |
| `120000` 商务住宅 | `住宅区` 或 `写字楼` | 粗类，必须结合 name/type 细分 |
| 科教文化中学校/科研机构 | `写字楼` 或 `图书馆` | 中；名称含图书馆时优先 `图书馆` |

如果 typecode 只能命中粗类，不能直接给高置信；必须由 name/type 关键词、距离、rank 等补证。

## 5. name 关键词辅助打分

`name` 通过关键词/正则规则参与本地打分，但只作为辅助证据。实现上应集中维护规则表，不散落字符串 grep。

| 内部 `place_type` | name 关键词 |
|---|---|
| `住宅区` | 小区、公寓、家园、花园、住宅、社区、苑 |
| `写字楼` | 大厦、写字楼、办公、公司、科技园、产业园、园区、研究院、中心、总部 |
| `餐厅` | 餐厅、饭店、食堂、咖啡、茶饮、火锅、烧烤、料理 |
| `商场` | 商场、商城、购物中心、广场、百货、商业 |
| `酒店` | 酒店、宾馆、旅馆、公寓酒店 |
| `公园` | 公园、绿地、湿地、景区 |
| `图书馆` | 图书馆、书店、阅览室 |
| `运动场所` | 运动场所、体育、健身房、健身、体育馆、球场、运动场、游泳馆、瑜伽、羽毛球、篮球、足球、gym、fitness、stadium |
| `地铁站` | 地铁、轨交、站 |
| `高铁站` | 高铁、火车站、铁路、动车 |
| `机场` | 机场、航站楼、候机楼 |
| `海边` | 海边、海滩、沙滩、码头、滨海 |

name 规则约束：

- `typecode` 与 name 同向：加分。
- 粗 typecode + name 命中：允许细分，例如 `120000` + “科技园” -> `写字楼`。
- name-only 命中：只能中低置信，最终 confidence 封顶 `0.55`。
- name 与强 typecode 冲突：typecode 优先，name 触发冲突降权。
- name 原文不上传、不持久化、不写 trace。

## 6. 单 POI 候选打分

每个 POI 先映射成一个 `place_type` 候选，再计算 `candidate_confidence`：

```text
candidate_confidence = clamp(
  distance_score +
  typecode_score +
  name_score +
  rank_score -
  accuracy_penalty -
  conflict_penalty,
  0.0,
  candidate_cap
)
```

`distance_score`：

| POI 距离 | score |
|---|---:|
| `<= 50m` | 0.42 |
| `<= 150m` | 0.34 |
| `<= 300m` | 0.22 |
| `<= 500m` | 0.12 |
| `> 500m` | 0.00，并过滤 |

`typecode_score`：

| typecode 证据 | score |
|---|---:|
| 精确强映射，例如机场/地铁/酒店/餐饮 | 0.30 |
| 中强映射，例如公司企业/购物/公园 | 0.24 |
| 粗类映射，例如商务住宅/交通设施泛类 | 0.14 |
| 无 typecode 或无法映射 | 0.00 |

`name_score`：

| name 证据 | score |
|---|---:|
| 与 typecode 映射同向 | 0.10 |
| 粗 typecode 下帮助细分 | 0.12 |
| name-only 命中 | 0.10 |
| 无命中 | 0.00 |
| 与强 typecode 冲突 | 不加分，并进入 conflict penalty |

`rank_score`：

| 高德排序 | score |
|---|---:|
| rank 0 | 0.04 |
| rank 1-2 | 0.02 |
| rank >= 3 | 0.00 |

`accuracy_penalty`：

| 定位精度 | penalty |
|---|---:|
| `<= 50m` | 0.00 |
| `<= 100m` | 0.06 |
| `<= 250m` | 0.14 |
| `<= 1000m` 或 reduced accuracy | 0.24 |
| `> 1000m` | 跳过 POI |

`conflict_penalty`：

| 冲突 | penalty |
|---|---:|
| 无明显冲突 | 0.00 |
| name 与强 typecode 指向不同内部类型 | 0.12 |
| 同一 POI 的 type 文本与 typecode 指向不同 | 0.08 |
| 定位样本 age `> 120s` | 0.20 |

`candidate_cap`：

| 证据组合 | cap |
|---|---:|
| 精确强 typecode + 距离 `<=150m` | 0.88 |
| 中强 typecode 或粗 typecode + name | 0.78 |
| 粗 typecode-only | 0.62 |
| name-only | 0.55 |
| type 文本-only | 0.50 |

## 7. Top-3 聚合与最终输出

候选处理：

1. 过滤 `candidate_confidence <= 0` 和距离 `> 500m`。
2. 按 POI 坐标四舍五入、name hash、内部 `place_type` 去重；同一 POI 保留最高分。
3. 按 `candidate_confidence` 降序取 up to 3 个候选。
4. 按 `place_type` 聚合：

```text
type_score = top.confidence + 0.08 * second_same_type + 0.04 * third_same_type
type_score = min(type_score, 0.88)
```

5. 选择最高 `type_score` 作为 Top-1。
6. 如果 Top-1 与 Top-2 差值 `< 0.12`，最终置信度减 `0.10`，质量降为 `noisy_mapping`。
7. 如果 Top-1 最终置信度 `< 0.35`，输出 unavailable 组合。

最终质量阈值：

| 条件 | 输出 |
|---|---|
| `confidence >= 0.70` 且无近似冲突 | `place_type_available=1`、`place_type_quality=exact_or_good_mapping` |
| `0.35 <= confidence < 0.70` 或存在 close runner-up | `place_type_available=1`、`place_type_quality=noisy_mapping` |
| `< 0.35`、无候选、请求失败、key 缺失 | `place_type=任意`、`place_type_available=0`、`place_type_confidence=0.0`、`place_type_quality=unavailable` |

## 8. 示例

### 8.1 科技园附近

输入 POI：

```text
name=某某科技园, typecode=120300, distance=38m
name=星巴克, typecode=050500, distance=85m
```

处理：

- 科技园：商务住宅粗类 + name 命中写字楼，候选为 `写字楼`，cap `0.78`。
- 星巴克：餐饮精确类 + name 同向，但距离更远，候选为 `餐厅`。
- Top-1 与 Top-2 如果分差足够，输出 `写字楼`；否则输出 `写字楼/noisy_mapping`。

### 8.2 商场里的餐厅

输入 POI：

```text
name=某购物中心, typecode=060100, distance=20m
name=某餐厅, typecode=050100, distance=24m
```

处理：

- `商场` 和 `餐厅` 都强，距离接近。
- 如果分差 `<0.12`，输出 Top-1 但降置信，`place_type_quality=noisy_mapping`。

### 8.3 POI 稀疏

输入 POI：

```text
pois=[]
```

处理：

- 不补齐 3 个候选。
- 输出 `任意/unavailable`。

## 9. 验收标准

- 高德 key 缺失或请求失败时，推荐流程继续执行。
- 默认上传 `place_candidates` Top-3；POI 候选数量支持 `0...3`，没有固定 3 个的假设。
- 兼容字段 `place_type`、`place_type_available`、`place_type_confidence`、`place_type_quality` 随 Top-1 一起输出。
- `typecode` 是主映射依据，name 只辅助加分、细分或降权。
- 支持 `运动场所`：体育休闲服务/运动场馆 typecode，或健身房、体育馆、球场等 name/type 关键词。
- name-only 候选不能输出高置信。
- trace 和上传 payload 不包含 POI name、地址、ID 或 API key。
- `source` 只使用脱敏来源标签，例如 `amap_typecode`、`amap_typecode_name`、`amap_name_keyword`。
