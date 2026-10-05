# 人物优化：可更改面与方法总集

> 本文回答一件事：**想让人物更好看/更顺，怎么改、改哪里、成本多大。**
> 每条都带出处（十二原则 / GDC / 参考项目 / 本项目实测），可直接执行。
>
> 配套：`docs/local/animation_gamefeel.md`（方法论原始笔记）、
> `docs/local/reference_projects.md`（参考项目评估）、`docs/local/movement_references.md`。
>
> 状态：`f0959a2`。标注 **〔备份分支〕** 的条目在 `backup/pre-rollback-camera-work`
> 上，尚未合入。

---

## 0. 诊断第一原则：表现层优先

来自 Swink《Game Feel》框架（gdad.wiki 整理）：

> **System layer vs Representation layer**（系统层 vs 表现层）
> 同一套系统数值，因**表现层**（动画时序、相机反应、音频、反馈）不同，
> 手感可以天差地别。**"感觉不对时，先查表现层，不要先动物理数值。"**

对照案例：Celeste 与 Hollow Knight 的跳跃物理相近，但前者动画快、色调明亮 →
紧迫；后者蓄力长、色调暗 → 沉重。差别几乎全在表现层。

**用法**：抱怨“人物很假/很卡/不好看”时，先问是**哪一层**：
剪影（读不出来吗）→ 时序（节奏对吗）→ 镜头（跟着对吗）→ 素材（模型本身够吗）→ 最后才数值。

---

## 1. 可更改面 · A：姿态与剪辑（`src/player/model_clips.gd`）

角色的动画状态机。速度 → 档位 → 剪辑 → 手动采样写骨。

| 可改项 | 现状 | 改法 | 成本 |
|---|---|---|---|
| 走/跑档位 | `walk_threshold` 0.25 / `run_threshold` 4.2（m/s），`gear_hold` 0.3s 滞回 | 直接调导出变量 | 0 |
| 播放速率 | 速度 / 剪辑作者速度，钳 0.6–2.4 | 同上 | 0 |
| 空中三段 | 起跳 `jump`（0.21s 动作，播完交棒）→ 下落 `fall`（循环）→ 落地 stop-blend | 换剪辑在 build 脚本的 `CLIP_SOURCES` | 中（需重建库） |
| 停稳混合 | 0.18s smoothstep 从移动姿势混到站姿 | `stop_blend` | 0 |
| 交棒淡入 | 0.1s cross-fade〔备份分支〕 | `cross_blend` | 已有（备份） |
| 落地判定 | 连续 8 tick 静止（≈0.13s）判落地——**跨平面也能落地** | `LAND_QUIET_TICKS` | 0 |
| **Squash & Stretch** | 十二原则第 1 条，起跳 +5% / 落地 −10%、体积守恒、弹簧回弹 | 〔备份分支〕已有；参数 `squash_rise/land/stiffness/damping` | 已有（备份） |

**剪辑从哪来**：`assets/animations/locomotion.res` 由
`tools/models/build_locomotion_library.gd` 构建（源库 ShooterLib/MeleeLib 的
walk/idle/sneak-run-s/jump/fall，CC-BY）。`tools/loop_probe.gd` 可验证每个
剪辑是否首尾闭合（真循环 vs 动作剪辑）。

## 2. 可更改面 · B：身体与朝向

| 可改项 | 文件 | 现状 | 改法 |
|---|---|---|---|
| 站姿呼吸/摆臂 | `model_stance.gd` | Spine/Neck 正弦摆动 + 手臂摆动 + 呼吸 | `sway_*` 参数；`Head` 每帧归位（供 C 叠加） |
| **头先转身** | `model_head_aim.gd` | 第一人称下头先吸收视角差（±70°），身体慢跟（3 rad/s） | `MAX_YAW_DEGREES` / `Player.body_follow_speed` |
| 身体朝向（第三人称） | `player.gd::_update_facing` | 朝**移动方向**，恒定角速度 10 rad/s（`angle_difference`，**不用 `lerp_angle`——π 处方向不定会抽搐**） | `turn_speed` |
| 变向时身体 | 同上 | 侧移/后退也转身（第三人称）——**第一人称已改为不转** | 改 `flat` 判定 |
| 头发/衣物跟随 | — | ❌ **未做**（十二原则第 5 条 Follow-through） | 头发骨弹簧摆动，参考 `ModelStance` 的 base-pose 缓存模式 |

## 3. 可更改面 · C：镜头（`src/player/camera_rig.gd`）

| 可改项 | 现状 | 出处/备注 |
|---|---|---|
| 高度 | `pivot_height` 1.38（乳房上方、颈根之下） | 用户实测调定 |
| 第一人称眼位 | 沿视线**前移 0.24**（冲刺 0.46，随速度拉伸） | 低头看到胸而非躯干剖面 |
| 前方净空 | 前移量取 `min(想要, 净空 − 0.06)` | 贴墙/贴物不穿模 |
| 头部隐藏 | 专用可见层 20 + **相机 cull_mask**（**不是 `mesh.visible`**，那会连拍照/第三人称/联机一起坑） | “只有第一人称藏头” |
| 跟随速率 | 三轴统一 14 | 〔备份分支〕改为**不对称**：水平 14 / 垂直 7 / 上升 4（GDC 2016） |
| 跳/落脉冲 | 〔备份分支〕起跳 −0.10m、落地按冲击速度、下沉 20 回弹 10（**不对称回弹**=体感的全部） | clarkgreenrepos |
| 横移倾斜 | **已禁用**（`enable_strafe_tilt=false`）——实测报缺陷，机制保留 | 查清后再开 |
| 换装构图 | `set_wardrobe_framing()`：正面、人物偏左、暂停内即时应用 | 已定稿 |
| 屏幕震动 | ❌ 未做（GDC 2013：**0.1–0.3s、2–5 像素、强度分级、噪声而非随机**） | 抓取/焊接/落地可用 |

## 4. 可更改面 · D：运动物理（`src/player/player.gd`）

| 可改项 | 现状 | 备注 |
|---|---|---|
| 走/跑/蹲速度 | `walk_speed` 5.2 / `sprint_speed` 8.6 / `crouch_speed` 2.4 | 体力系统挂在冲刺上 |
| 加速/减速 | `acceleration` / `deceleration`（**非线性=ADSR 感**） | GDC 建议用渐近平均 |
| 跳跃 | `jump_velocity` + **可变跳高**（松开保留 45% 上升速度） | 采纳自 godot-4-state-machine-controller |
| Coyote / Jump buffer | 有 | 标准配置 |
| 空中控制 | `air_control` 系数 | **候选**：air-strafe 加速、Quake 式动量保留（clarkgreenrepos） |
| 落地响应 | 静默计帧（与上表同源） | 跨平面不再卡死 |
| **滑行惯性** | ❌ 未做 | clarkgreenrepos 的 `slide`（松键后惯性滑 + 摩擦衰减） |
| 蹲姿碰撞 | 单一胶囊缩放 | **候选**：两种蹲姿（头降 / 腿上移），后者跳跃时镜头更稳 |

## 5. 可更改面 · E：模型与素材

- **基准模型**：`assets/characters/base_female.vrm`（SiroinoSotai 躯干 CC0 + Akane 头 CC0，102 关节 15 网格）
- **形状键**：9 条形体滑条（胸/臀/腮红…），服装按同名零映射表自动跟随
- **服装**：9 件可见性开关
- **候选**：把“唯美”落到**素材**上——例如换更柔的站姿剪辑、加头发/裙摆的物理摆动（Follow-through）、提高 VRM 的布料质量

## 6. 可更改面 · F：反馈层（最便宜的高感知）

| 手段 | 状态 |
|---|---|
| 通知/提示（Events.notify） | ✅ 有 |
| 音效 | ✅ 环境音（CC0）；**动作音缺失**（起跳/落地/抓取/焊接） |
| 粒子 | ❌ 未做（落地尘土、焊接火花——celjapu 的 juice 清单） |
| 顿帧 hitstop | ❌ 未做（GDC 2012 Juice It or Lose It） |
| 震动 | ❌ 未做（见 §3） |

> Vlambeer 的量化标准：**一次按键应引发 5+ 种反馈**（视觉+音效+镜头+粒子+顿帧）。
> 我们大多只有 1–2 种——这是“廉价感”最廉价的解法。

---

## 7. 候选清单（按性价比排序，均未做）

| 优先 | 项 | 出处 | 成本 | 预期收益 |
|---|---|---|---|---|
| ★★★ | **剪影测试**作为验收 | 十二原则 3（Staging） | 零代码 | 暴露“动作不可读”，也能验收后续所有改动 |
| ★★★ | **动作音效 + 落地尘土 + 顿帧** | Vlambeer / GDC 2012 | 小 | “廉价感”最直接的解法 |
| ★★☆ | **起跳预备**（3–5 帧下蹲） | 十二原则 2（Anticipation） | 小 | 起跳可读性、力量感 |
| ★★☆ | **屏幕震动**（分级、噪声驱动） | GDC 2013 | 小 | 抓取/焊接/落地 |
| ★★☆ | **头发/衣物跟随** | 十二原则 5（Follow-through） | 中 | “唯美”观感提升最明显 |
| ★☆☆ | 滑行惯性 / 空中转向加速 | clarkgreenrepos | 中 | 手感（但沙盒里未必明显） |
| ★☆☆ | Ragdoll 布娃娃状态 | Jeh3no 控制器 | 中 | 目前无战斗，等死亡表现 |

---

## 8. 方法论出处

| 来源 | 内容 | 笔记 |
|---|---|---|
| Johnston & Thomas《The Illusion of Life》 | **十二原则**；游戏化改写见 Meta Horizon 动画质量文档、lobehub "Animation Principles for Interactive Media"（含帧数：预备 3–5f / 动作 2–4f / 跟随 3–6f） | `docs/local/animation_gamefeel.md` |
| Swink《Game Feel》 | 表现层 vs 系统层、反馈延迟 <100ms、原子/微机制 | 同上 |
| GDC 2012 *Juice It or Lose It* | 分层反馈 | 同上 |
| GDC 2013 *The Art of Screenshake* | 震动的量级与克制 | 同上 |
| GDC 2016 *Juicing Your Cameras* | 位移 vs 旋转、噪声 vs 随机、**不对称渐进平均**、取景 | 同上 |
| clarkgreenrepos/Godot-Character-Movement-Plugin | 镜头 bob/倾斜、滑行、空中转向、蹲姿碰撞 | `docs/local/reference_projects.md` |
| Jeh3no/Godot-Third-Person-Controller | 5 态 FSM + Ragdoll + 相机三模式 | 同上 |

## 9. 验收标准（建议）

1. **剪影可读**：每个状态渲成纯黑剪影，远处能辨认（staging）
2. **过渡无卡**：起跳/落地/急停/180° 转身，各录一段慢放，无单帧跳变
3. **反馈达标**：落地一次按键触发 ≥3 种反馈（音/尘/镜头/震动任选）
4. **性能**：市民 40 人仍 ≤25 draw call、三道闸有效（已有 `perf_probe`）
