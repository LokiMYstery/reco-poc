# iOS 前端 PoC 问卷 SPEC

本文定义 iOS 前端 PoC 的首版问卷题目、选项和字段映射。

目标：用非常短的问卷获得用户 intent，让推荐系统在冷启动或低权限上下文下仍有一个弱先验。问卷不是 iOS 系统权限，但在实验中按一种“软授权 / 用户同意”处理：用户可以填写，也可以完全跳过。

---

## 1. 设计原则

1. **短问卷优先**：首版不要做成长问卷，避免打断实验流程。
2. **intent 覆盖完整**：必须覆盖现有后端支持的 `initial_need` / `initial_needs` 枚举。
3. **允许跳过**：用户可以不填问卷，前端应标记 `questionnaire_available=0`、`intent_available=0`。
4. **允许后续修改**：用户可在 Setup / 权限问卷维护页修改 intent，修改后立即重派生虚拟用户和 virtual context。
5. **只作为弱先验**：问卷 intent 不覆盖实时上下文和真实反馈。

---

## 2. 首版问卷结构

首版建议 3 题：

| 顺序 | 题目 | 是否必答 | 字段 | 说明 |
|---:|---|---:|---|---|
| Q1 | 你现在/通常最想用音乐帮助什么？ | 否 | `initial_need` / `intent` | 单选主 intent，最重要 |
| Q2 | 你还可能有哪些需求？ | 否 | `initial_needs` | 多选补充 intent，覆盖完整枚举 |
| Q3 | 哪个标签更像你？ | 否 | `user_tag` | 单选粗标签，可跳过 |

`gender` 首版不建议作为默认题目强制展示。若需要采集，可放在“更多资料/可选信息”里，并默认可跳过。

---

## 3. Q1：主 Intent 单选

### 题目

```text
你现在/通常最想用音乐帮助什么？
```

### UI 类型

单选。

### 写入字段

```text
intent
initial_need
intent_available = 1
questionnaire_available = 1
```

### 选项，覆盖全部 intent 枚举

| label | value / `initial_need` | 可辅助的场景方向 |
|---|---|---|
| 学习/工作专注 | `学习/工作专注` | 专注、图书馆、阅读 |
| 睡眠/午休 | `睡眠/午休` | 深睡眠、睡午觉、婴儿安睡 |
| 放松/减压 | `放松/减压` | 放松、减压、冥想 |
| 运动/健身 | `运动/健身` | 健身、跑步、瑜伽 |
| 通勤/出行 | `通勤/出行` | 通勤、跑步、放松 |
| 情绪陪伴 | `情绪陪伴` | 深夜EMO、减压、放松 |
| 家庭/照护 | `家庭/照护` | 婴儿安睡、胎教、宠物陪伴 |
| 游戏娱乐 | `游戏娱乐` | 游戏、放松 |
| 阅读陪伴 | `阅读陪伴` | 阅读、图书馆、专注 |

### 跳过行为

如果用户跳过 Q1 且没有回答 Q2：

```json
{
  "questionnaire_available": 0,
  "intent_available": 0
}
```

如果用户跳过 Q1 但回答了 Q2：

- `intent_available=1`
- `initial_need` 可以取 Q2 中用户选的第一个选项，或留空只传 `initial_needs`。
- 推荐：首版为了简单，取 Q2 的第一个选项作为 `initial_need`，同时保留完整 `initial_needs`。

---

## 4. Q2：补充 Intent 多选

### 题目

```text
你还可能有哪些需求？可多选。
```

### UI 类型

多选。

### 写入字段

```text
initial_needs: [String]
```

### 选项

和 Q1 完全一致，确保枚举覆盖一致：

```text
学习/工作专注
睡眠/午休
放松/减压
运动/健身
通勤/出行
情绪陪伴
家庭/照护
游戏娱乐
阅读陪伴
```

### 推荐交互

- 如果用户已在 Q1 选择了主 intent，Q2 默认可以不选。
- 如果用户在 Q2 里也选择了 Q1 的同一项，可以保留；也可以 UI 上自动勾选并允许取消。
- 首版建议简单处理：Q2 多选结果包含用户实际勾选项，不自动合并 Q1。
- 提交时，如果 Q2 为空，可以只传 `initial_need`。

---

## 5. Q3：粗用户标签单选

### 题目

```text
哪个标签更像你？
```

### UI 类型

单选，可跳过。

### 写入字段

```text
user_tag
```

### 选项

| label | value |
|---|---|
| 不选择 | `任意` |
| 学生 | `学生` |
| 母婴用户 | `母婴用户` |
| 女性 | `女性` |
| 养宠物 | `养宠物` |

### 说明

- `user_tag` 只作为冷启动弱先验。
- 不应因为用户选择某标签就覆盖实时上下文或真实反馈。
- 如果用户跳过，传 `任意` 或不传均可；首版建议传 `任意`，方便调试。

---

## 6. 可选题：性别

首版不建议默认要求填写。

如需要展示，建议放在可选折叠区域：

### 题目

```text
你的性别？可跳过。
```

### 字段

```text
gender
```

### 选项

```text
任意
女性
男性
不便透露
```

### 说明

- 不强制采集。
- 不用于硬规则。
- 如果跳过，传 `不便透露` 或不传均可；首版建议传 `不便透露`。

---

## 7. 问卷状态字段

### 完整填写或部分填写

只要用户选择了至少一个 intent：

```json
{
  "questionnaire_available": 1,
  "intent_available": 1
}
```

### 完全跳过

```json
{
  "questionnaire_available": 0,
  "intent_available": 0
}
```

### 只填标签，不填 intent

如果用户只填了 `user_tag`，但没有选择 Q1/Q2 intent：

```json
{
  "questionnaire_available": 1,
  "intent_available": 0
}
```

---

## 8. 字段映射规则

### 8.1 单选主 intent

Q1 选择：

```text
学习/工作专注
```

输出：

```json
{
  "intent": "学习/工作专注",
  "initial_need": "学习/工作专注",
  "questionnaire_available": 1,
  "intent_available": 1
}
```

### 8.2 多选补充 intent

Q2 选择：

```text
睡眠/午休
放松/减压
```

输出：

```json
{
  "initial_needs": ["睡眠/午休", "放松/减压"],
  "questionnaire_available": 1,
  "intent_available": 1
}
```

### 8.3 Q1 + Q2 同时存在

Q1：

```text
学习/工作专注
```

Q2：

```text
放松/减压
阅读陪伴
```

输出：

```json
{
  "intent": "学习/工作专注",
  "initial_need": "学习/工作专注",
  "initial_needs": ["放松/减压", "阅读陪伴"],
  "questionnaire_available": 1,
  "intent_available": 1
}
```

### 8.4 完整示例

```json
{
  "intent": "运动/健身",
  "initial_need": "运动/健身",
  "initial_needs": ["放松/减压", "通勤/出行"],
  "user_tag": "任意",
  "gender": "不便透露",
  "questionnaire_available": 1,
  "intent_available": 1
}
```

---

## 9. 与虚拟用户 Permission Mask 的关系

问卷是一种软授权，参与 `questionnaire` mask：

```text
questionnaire=full  -> Q1/Q2/Q3 可用，可能包含 gender
questionnaire=basic -> 至少有 Q1 主 intent
questionnaire=none  -> 完全跳过问卷
```

典型虚拟用户：

| 虚拟用户 | questionnaire mask | 说明 |
|---|---|---|
| `u_full_permission` | `full` | 全上下文 + 完整问卷 |
| `u_full_no_questionnaire` | `none` | 全传感器，但无 intent |
| `u_intent_only_minimal_context` | `full` | 系统权限很少，但有问卷 intent |
| `u_minimal_context` | `none` | 权限和问卷都少 |

用户修改问卷后，前端应立即：

1. 保存当前问卷答案。
2. 更新 `questionnaire_available` / `intent_available`。
3. 重新派生虚拟用户和 virtual context。
4. 如果用户的实际意愿组合不匹配内置虚拟用户，生成 ad hoc virtual user。

---

## 10. 验收标准

1. 问卷可以完全跳过。
2. Q1 单选覆盖全部 9 个 intent 枚举。
3. Q2 多选覆盖同一组 9 个 intent 枚举。
4. Q3 粗标签覆盖 `任意`、`学生`、`母婴用户`、`女性`、`养宠物`。
5. 性别题如果实现，必须可跳过。
6. 至少一个 intent 被选择时，`intent_available=1`。
7. 完全跳过问卷时，`questionnaire_available=0` 且 `intent_available=0`。
8. 修改问卷后立即触发虚拟用户和 virtual context 重派生。
9. `intent` 与 `initial_need` 在首版中保持同值，便于兼容后端。
10. 问卷 intent 只作为弱先验，不覆盖实时上下文和最终反馈。

