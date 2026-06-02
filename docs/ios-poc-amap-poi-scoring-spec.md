# SPEC: iOS 高德地点证据融合链路

## Metadata

- Date: 2026-06-02
- Scope: iOS / Swift 前端 PoC 使用高德 Web 服务和 CoreLocation 推导 `place_candidates` 与 `place_type_*`
- Upstream SPEC: `docs/ios-frontend-poc-spec.md`
- Backend contract: `docs/frontend-backend-payload-contract.md`
- Status: planning SPEC; no backend contract change

## 1. 目标与输出

本 SPEC 的目标是回答“这里是哪里”，不是直接判断最终音乐场景。

前端在本地融合多个地点证据源，输出脱敏后的内部地点候选：

```json
{
  "place_candidates": [
    {
      "place_type": "住宅区",
      "confidence": 0.76,
      "distance_m": 18.0,
      "source": "amap_regeo_aoi_building_poi",
      "quality": "exact_or_good_mapping"
    }
  ],
  "place_type": "住宅区",
  "place_type_available": 1,
  "place_type_confidence": 0.76,
  "place_type_quality": "exact_or_good_mapping"
}
```

兼容字段 `place_type`、`place_type_available`、`place_type_confidence`、`place_type_quality` 始终随 Top-1 候选一起传。`place_candidates` 允许 `0...3` 个候选；没有足够证据时省略该字段，不能强行补齐。

内部地点枚举固定沿用现有后端合同：

```text
任意、住宅区、商场、酒店、餐厅、公园、写字楼、机场、图书馆、海边、户外、在途、高铁站、地铁站、运动场所
```

## 2. 总体策略

单一 POI name 或单一 typecode 不能稳定回答“这里是哪里”。前端应融合以下证据：

| 证据源 | 用途 | 上传原文 |
|---|---|---:|
| CoreLocation 坐标和精度 | 触发高德查询、计算距离、判断定位可信度 | 经用户授权后可传经纬度给后端 geo cluster |
| 高德坐标转换 | WGS84/CoreLocation -> 高德坐标，避免周边查询偏移 | 否 |
| 高德逆地理编码 regeo | 获得 AOI、neighborhood、building、addressComponent、附近 POI | 否 |
| 高德周边 POI around | 获得可排序、多类型候选 POI | 否 |
| 高德 POI detail | 对 winner/runner-up 补充 children、business、indoor 等详情 | 否 |
| 本地关键词/规则 | 将 provider 字段映射到内部 `place_type` | 否 |
| 用户本地短时稳定性 | 同一地点连续结果去抖、提升稳定证据 | 否，第一版可只进入 trace |

第一阶段仍只向后端上传 `place_candidates` 和兼容字段；不新增后端必填字段。经纬度仍按已有合同作为可选增强字段上传，用于后端 routine / geo cluster，不作为后端硬规则。

## 3. 数据获取链路

### 3.1 定位输入

1. 获取 iOS location best sample：`latitude`、`longitude`、`horizontal_accuracy_m`、timestamp。
2. 如果定位不可用、样本过旧或 `horizontal_accuracy_m > 1000`，跳过高德地点融合，输出 unavailable 组合。
3. 坐标系统处理：
   - 默认 `RECO_AMAP_INPUT_COORDSYS=gps`：先调用高德坐标转换得到高德坐标。
   - 如果实测输入已是高德坐标，可配置为 `autonavi`，跳过转换。
   - 当配置为 `gps` 时，around/regeo/detail 查询只能使用转换后的高德坐标；原始 CoreLocation 坐标只作为本地输入和后端 geo cluster 可选字段。
   - trace 必须记录 `amap.coordinate_convert`，并区分 `input_coordsys=gps;conversion=amap` 与 `input_coordsys=autonavi;conversion=skipped`。

### 3.2 高德查询顺序

前端按以下顺序收集证据，任何一步失败都不能阻塞推荐：

1. **坐标转换**：`/v3/assistant/coordinate/convert`。
2. **逆地理编码**：`/v3/geocode/regeo`，优先使用：
   - `extensions=all`
   - `radius=200` 起步；定位精度差时可放大到 `min(500, max(200, accuracy * 2))`
   - `roadlevel=1`
   - `homeorcorp=1` 作为住宅/宿舍倾向 probe；如果后续要比较办公倾向，可在调试模式额外跑 `homeorcorp=2`
3. **周边 POI around**：`/v5/place/around`，使用高德坐标：
   - 默认 `radius=300`；定位精度或 POI 稀疏时扩大到 `500`
   - `sortrule=distance`
   - `page_size=25`，避免宿舍/校园大 AOI 被附近餐饮/校门/教学楼挤出 Top-10
   - `show_fields=business,children,indoor,navi`
   - `types` 不只用粗类；应覆盖住宅/商务住宅、住宿、餐饮、购物、体育、科教文化、交通、风景名胜、公司企业等
4. **POI detail 可选补证**：仅对 Top winner 和 close runner-up 调用 detail，补充 children/subPOI、business、indoor/cpid 等字段。

坐标转换失败时，不能用原始 GPS 坐标兜底调用高德 regeo/around；应输出 unavailable 或仅使用非高德地点信号，避免 GCJ-02 偏移导致错误 POI。

## 4. 隐私与 trace

本地可以读取并融合以下原始字段，但不能上传或持久化原文：

| 字段 | 来源 | 用途 | 是否上传 |
|---|---|---|---:|
| `name` | POI / AOI / building / neighborhood | 关键词、冲突判断、容器识别 | 否 |
| `type` | POI / AOI / building / neighborhood | provider 类型辅助映射 | 否 |
| `typecode` | POI | 主映射依据之一 | 否 |
| `id` | POI | detail 查询和本地去重 | 否 |
| `address` | POI / regeo | 本地调试，不进 payload | 否 |
| `location` | POI | 距离计算 | 否 |
| `distance` | POI / regeo POI / AOI | 候选打分 | 否 |

trace 必须脱敏：

- 允许：`place_type`、候选分、距离、typecode、source、reason code、证据族计数、winner/runner-up 的内部类型。
- 不允许：真实 API key、完整请求 URL、POI/AOI/building/neighborhood 原始名称、地址、高德 POI ID。

`source` 使用脱敏来源标签，例如：

```text
amap_regeo_aoi
amap_regeo_building
amap_regeo_neighborhood
amap_regeo_poi
amap_around_typecode
amap_around_typecode_name
amap_around_name_keyword
amap_detail_children
amap_fused_evidence
```

## 5. 证据模型

地点判定分两层：

1. **Provider evidence**：每条 regeo/around/detail 证据先映射成内部 `place_type` 候选。
2. **Fusion evidence**：按内部 `place_type` 聚合不同来源证据，输出 Top-3。

每条证据建议保存以下本地结构：

```text
place_type
confidence
distance_m
source
quality
provider_kind   // regeo_aoi, regeo_building, regeo_neighborhood, regeo_poi, around_poi, detail_child
evidence_tags   // residential_keyword, campus_container, sports_keyword, typecode_strong...
```

只上传脱敏后的 `PlaceCandidate`。

## 6. typecode 主映射

`typecode` 仍是强证据，但不能单独覆盖所有场景。特别是学校/大学和商务住宅粗类都要避免硬判。

| 高德 typecode / 前缀 | 内部 `place_type` | 策略 |
|---|---|---|
| `050000` 餐饮服务 | `餐厅` | 强 |
| `060000` 购物服务 | `商场` | 中强；便利店等小店降权 |
| `100000` 住宿服务 | `酒店` | 强；不要把酒店式公寓误归住宅区 |
| `080000` 体育休闲服务 / `0801xx` 运动场馆 | `运动场所` | 强 |
| `110100` / 风景名胜中公园类 | `公园` | 中强 |
| 图书馆精确类 | `图书馆` | 强 |
| 机场精确类 | `机场` | 强 |
| 地铁站精确类 | `地铁站` | 强 |
| 火车站/高铁站精确类 | `高铁站` | 强 |
| `150000` 交通设施服务但无法细分 | `在途` | 粗类；结合 motion/距离 |
| `170000` 公司企业 | `写字楼` | 中强 |
| 商务住宅中明确住宅/小区/宿舍/公寓类 | `住宅区` | 中强；name/type/AOI 同向可高置信 |
| 商务住宅粗类 | `住宅区` 或 `写字楼` | 粗类；必须结合 name/type/AOI/building |
| 科教文化中图书馆 | `图书馆` | 强 |
| 科教文化中学校/高等院校/科研机构 | 不直接映射成 `写字楼` | 作为 `campus_container` 弱证据；由 name/AOI/building/nearby POI 决定住宅、运动、图书馆、餐厅等细分 |

学校类 typecode 不直接给住宿或运动加分。正确处理方式：

- `学校 + 宿舍/学生公寓/生活区/楼栋` -> `住宅区`
- `学校 + 体育馆/操场/运动场/健身` -> `运动场所`
- `学校 + 图书馆/书店/阅览室` -> `图书馆`
- `学校 + 食堂/餐厅/咖啡` -> `餐厅`
- 只有泛学校证据时，不输出高置信细类；可作为 `noisy_mapping` 或降低到 `任意`

## 7. name/type 关键词辅助

`name` 和 `type` 是辅助证据，不是最终事实。关键词要区分**空间功能词**和**容器词**。

### 7.1 功能词

| 内部 `place_type` | name/type 关键词 |
|---|---|
| `住宅区` | 小区、公寓、学生公寓、宿舍、学生宿舍、宿舍楼、寝室、生活区、住宅、社区、家园、花园、苑、楼栋、楼座 |
| `写字楼` | 大厦、写字楼、办公、公司、总部、办公楼、商务楼、联合办公 |
| `餐厅` | 餐厅、饭店、食堂、咖啡、茶饮、火锅、烧烤、料理、canteen |
| `商场` | 商场、商城、购物中心、百货、商业街 |
| `酒店` | 酒店、宾馆、旅馆、公寓酒店、民宿、客栈 |
| `公园` | 公园、绿地、湿地、景区 |
| `图书馆` | 图书馆、书店、阅览室 |
| `运动场所` | 体育馆、体育场、操场、运动场、球场、健身房、健身、游泳馆、瑜伽、羽毛球、篮球、足球、gym、fitness、stadium |
| `地铁站` | 地铁、轨交、subway、metro |
| `高铁站` | 高铁、火车站、铁路、动车 |
| `机场` | 机场、航站楼、候机楼 |
| `海边` | 海边、海滩、沙滩、码头、滨海 |

### 7.2 容器词

这些词不应单独映射成 `写字楼`：

```text
学校、大学、学院、校区、校园、研究院、园区、科技园、产业园、中心
```

容器词只表达大范围环境。它们可以调整置信度和冲突判断，但不能覆盖更具体的功能词。例如：

- `XX大学学生宿舍`：`宿舍` 是功能词，优先 `住宅区`；`大学` 只是容器词。
- `XX大学体育馆`：`体育馆` 是功能词，优先 `运动场所`。
- `XX大学图书馆`：`图书馆` 是功能词，优先 `图书馆`。
- `XX大学`：只有容器词，不给高置信细分类。

## 8. regeo 证据优先级

逆地理编码返回的 AOI、building、neighborhood 比周边 POI 更接近“我处在什么空间里”。

建议优先级：

| regeo 字段 | 作用 | 默认权重 |
|---|---|---:|
| AOI 且 `distance=0` | 点在 AOI 内，强容器证据 | 0.34 |
| building | 楼宇/建筑物证据，适合宿舍楼、办公楼、商场 | 0.32 |
| neighborhood | 小区/社区证据，适合住宅区 | 0.30 |
| regeo pois | 附近 POI 证据，权重低于 around Top POI | 0.18 |
| roads / streetNumber | 辅助交通/在途，不直接给住宅/办公 | 0.08 |

regeo 规则：

- AOI/name/type 命中校园容器时，先标记 `campus_container`，再等待 building/neighborhood/POI 细分。
- AOI/name/type 命中小区、住宅、宿舍、学生公寓、生活区时，可以直接形成 `住宅区` 候选。
- building 命中宿舍/学生公寓/寝室/楼栋且处于校园 AOI 内时，`住宅区` 候选置信度上限可到 `0.82`。
- neighborhood 命中住宅词时，`住宅区` 候选置信度上限可到 `0.86`。
- 如果 AOI 是校园、around Top POI 是餐厅/教学楼，但 building/neighborhood 缺失，则不要强判住宅区。

## 9. around POI 证据

around POI 继续提供附近候选，但不再作为唯一主链路。

### 9.1 查询策略

1. 默认半径 `300m`；无候选或定位精度 `>100m` 时扩大到 `500m`。
2. `page_size=25`，减少宿舍/校园 POI 被 Top-10 截断的问题。
3. 使用分组证据，而不是只看第一个 POI：
   - 同类候选数量
   - 最近距离
   - Top candidate rank
   - typecode 强度
   - name/type 功能词
   - 是否与 regeo AOI/building/neighborhood 同向

### 9.2 候选打分

每个 around POI 映射为本地候选：

```text
poi_confidence = clamp(
  distance_score +
  typecode_score +
  function_keyword_score +
  rank_score +
  regeo_agreement_bonus -
  accuracy_penalty -
  conflict_penalty,
  0.0,
  candidate_cap
)
```

`function_keyword_score` 替代旧 `name_score`：只有功能词加分，容器词不单独加分。

| name/type 证据 | score |
|---|---:|
| 功能词与 typecode 同向 | 0.12 |
| 粗 typecode 下功能词帮助细分 | 0.14 |
| name-only 功能词命中 | 0.10 |
| 只有容器词 | 0.00 |
| 功能词与强 typecode 冲突 | 不加分，并进入 conflict penalty |

`candidate_cap`：

| 证据组合 | cap |
|---|---:|
| 精确强 typecode + 功能词同向 + 距离 `<=150m` | 0.88 |
| regeo AOI/building/neighborhood 同向 + POI 同向 | 0.86 |
| 中强 typecode 或粗 typecode + 功能词 | 0.78 |
| 粗 typecode-only | 0.62 |
| name-only 功能词 | 0.55 |
| 只有容器词 | 0.35 |

## 10. 融合算法

按内部 `place_type` 聚合 evidence：

```text
type_score =
  0.34 * best_regeo_aoi_score +
  0.32 * best_regeo_building_score +
  0.30 * best_regeo_neighborhood_score +
  0.26 * best_around_poi_score +
  0.10 * same_type_support_score +
  0.08 * stability_score -
  conflict_penalty
```

说明：

- 每个来源缺失时该项为 `0`，不当负证据。
- `same_type_support_score` 来自同类 evidence 数量，最多加 `0.10`。
- `stability_score` 第一版可只使用同一次采集内的一致性；后续再接短时本地缓存。
- `conflict_penalty` 处理 close runner-up、多功能混合楼、定位精度差、样本过旧。
- 最终 score clamp 到 `0...0.90`。

Top-1 决策：

1. 取最高 `type_score` 作为 Top-1。
2. 输出 Top-3 内部地点候选。
3. 如果 Top-1 与 Top-2 差值 `<0.12`，Top-1 质量降为 `noisy_mapping`。
4. 如果 Top-1 `<0.35`，输出 unavailable。

最终质量阈值：

| 条件 | 输出 |
|---|---|
| `confidence >= 0.70` 且无 close runner-up | `place_type_available=1`、`place_type_quality=exact_or_good_mapping` |
| `0.35 <= confidence < 0.70` 或存在 close runner-up | `place_type_available=1`、`place_type_quality=noisy_mapping` |
| `<0.35`、无候选、请求失败、key 缺失 | `place_type=任意`、`place_type_available=0`、`place_type_confidence=0.0`、`place_type_quality=unavailable` |

## 11. 特定场景规则

### 11.1 学生宿舍 / 学生公寓

学生宿舍、学生公寓、寝室、生活区都归 `住宅区`。

推荐证据解释：

```text
AOI: XX大学
building: XX学生宿舍
around: 食堂、教学楼、体育馆
```

处理：

- AOI 标记 `campus_container`，不直接判写字楼。
- building 命中宿舍功能词，生成 `住宅区` 强候选。
- 食堂/体育馆作为餐厅/运动场所候选保留在 Top-3，但不能覆盖宿舍楼证据。
- 输出示例：`住宅区 0.78 exact_or_good_mapping`，runner-up `餐厅` 或 `运动场所`。

### 11.2 泛校园

```text
AOI: XX大学
building: missing
around: 教学楼、食堂、体育馆
```

处理：

- 只有校园容器，不输出高置信 `写字楼`。
- 根据 around POI 输出 `餐厅`、`运动场所`、`图书馆` 等候选。
- 如果候选冲突接近，输出 `noisy_mapping`。

### 11.3 商场里的餐厅

```text
AOI/building: 某购物中心
around: 某餐厅 24m
```

处理：

- building/AOI 给 `商场` 候选。
- around 餐厅给 `餐厅` 候选。
- 分差小则 Top-1 降为 `noisy_mapping`，Top-3 保留两者。

### 11.4 科技园 / 产业园

科技园、产业园、园区是容器词，不直接等于写字楼。

处理：

- 如果 building/POI 命中公司、办公楼、总部，输出 `写字楼`。
- 如果命中公寓、宿舍、生活区，输出 `住宅区`。
- 只有园区容器时，低置信或 `任意/noisy_mapping`。

## 12. 前端诊断面板

为方便调试宿舍/校园误判，前端诊断页应展示脱敏聚合信息：

- location accuracy、坐标系统、坐标转换是否成功。
- `amap.coordinate_convert` detail：`input_coordsys=gps;conversion=amap` 或 `input_coordsys=autonavi;conversion=skipped`。
- regeo 是否成功、AOI/building/neighborhood 是否有可用证据，但不显示原始名称。
- around POI 结果数量、usable 数量、Top-3 内部类型、距离、source。
- fusion winner、runner-up、margin、quality。
- 失败 reason code：`amap_disabled`、`amap_key_missing`、`regeo_failed`、`around_failed`、`low_accuracy`、`ambiguous_low_margin` 等。

## 13. 验收标准

- 高德 key 缺失、regeo 失败、around 失败时，推荐流程继续执行。
- 默认配置为 `RECO_AMAP_INPUT_COORDSYS=gps` 时，必须先完成 GPS/CoreLocation -> 高德坐标转换，再调用 regeo/around；坐标转换失败不能直接用原始 GPS 坐标查高德。
- 单元测试必须覆盖 `gps -> coordinate_convert -> around` 路径，并断言 trace 包含 `input_coordsys=gps;conversion=amap`。
- `学生宿舍`、`学生公寓`、`宿舍楼`、`寝室`、`生活区` 等 name/type/building 命中时，候选应归 `住宅区`。
- `学校`、`大学`、`学院`、`校区`、`校园` 只作为 campus/container 证据，不能单独输出高置信 `写字楼`、`住宅区` 或 `运动场所`。
- 学校类 typecode 不直接给住宿或运动加分；必须由功能词、AOI/building/neighborhood、around POI 或 detail children 补证。
- POI name-only 候选不能输出高置信；只有容器词时 cap 不超过 `0.35`。
- regeo AOI/building/neighborhood 与 around POI 冲突时，输出 Top-3 并降级 `place_type_quality=noisy_mapping`。
- 默认上传 `place_candidates` Top-3；候选数量支持 `0...3`，没有固定 3 个的假设。
- 兼容字段 `place_type`、`place_type_available`、`place_type_confidence`、`place_type_quality` 随 Top-1 一起输出。
- trace 和上传 payload 不包含 POI/AOI/building/neighborhood 原始名称、地址、ID 或 API key。
- `source` 只使用脱敏来源标签。
