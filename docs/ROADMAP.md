# 开发路线图：MIT 协议的 GMod 式沙盒

> 定位：一个**受 Garry's Mod 启发、以 MIT 协议发布**的沙盒游乐场——生成道具、
> 用工具枪改造世界、NPC 在街上过自己的生活、一切玩法面都向 mod 开放。
> 复刻的是 GMod 的**玩法骨架**（沙盒物理 + 工具枪 + NPC + Lua 式扩展生态），
> 不使用任何 Valve/GMod 的代码、模型或资产。
>
> 单机优先。引擎 Godot 4.7 / Forward+ / Jolt Physics。

---

## 已有的地基（现状盘点）

| 能力 | 状态 | 所在 |
|---|---|---|
| 物理沙盒底座 | ✅ Jolt + 代码构建场景 | `src/boot` |
| 载具（驾驶/上下车） | ✅ 可复制到任何 RigidBody 道具 | `src/vehicle/` |
| 战斗接口（无平衡） | ✅ Attacker / Damageable / 武器参考实现 | `src/combat/` |
| 双 mod 加载器 | ✅ `mod.json`（自研）+ `manifest.json`（godot-mod-loader） | `src/core/mod_host.gd` 等 |
| 脚本 mod（Lua / 沙盒 GDScript） | ✅ 探测、降级、ScriptBridge 门面 | `src/core/scripting_runtimes.gd`、`script_bridge.gd` |
| 地图源缝 + 城市实现 | ✅ `MapSource` + PLATEAU 渋谷（可选 SDK，ClassDB 探测） | `src/map/` |
| 标签驱动人流核心 | ✅ 标签/日程/选点/缓存/就绪报告，测试钉住 | `src/mobility/` |
| 行人 agent（沿日程走、贴墙滑行） | ✅ 直线路径 + `move_and_slide` | `src/mobility/pedestrian_agent.gd` |
| 地点表导出工具 | ⚠️ 已写，大文件导出卡住待查（见 P2） | `tools/city_export_activity.gd` |

---

## P0 沙盒地基 —— 「能生成、能抓、能冻、能删」

GMod 的第一分钟是：按 Q 开生成菜单，点一个箱子，用物理枪拎起来，冻在半空。

- **道具系统**：`PropDef` 目录（箱/球/板/坡道/桶…，全部代码构建网格），RigidBody + 质量/材质。
- **生成菜单**：快捷键呼出（gmod 的 Q），分类浏览 + 点击生成在准星处；**mod 可注册道具**（走 `ModContext`，与现有 vehicle/poi 注册同缝）。
- **物理枪 v1**：射线抓取（持有跟随准星、滚轮距离）、左键投掷、右键冻结（`freeze = true` + 视觉提示）、再按解冻。
- **移除**：对准目标删除（undo 键 + 工具）。
- **验收**：无头测试能 spawn 50 个道具不炸；冻结态物理静默；删除后引用干净。

## P1 工具枪 —— 「改造世界的语法」

- **工具枪框架**：射线命中 → 工具回调（命中实体/点/法线/玩家输入）；工具是**注册点**（`add_tool`），Lua mod 与核心同权。
- 首批工具：
  - **焊接**（两实体间 `Generic6DOFJoint3D`，可解除）
  - **绳索**（两点可拉伸约束，渲染线绳）
  - **复制器**（把一组实体+关节序列化成"蓝印"，一键重放——gmod duplicator）
  - **上色**（材质 albedo 修改）
- **验收**：焊接两个箱子拖动一个带动另一个；绳索吊起道具；复制一套斜坡结构。

## P2 NPC 与人流 —— 「街上有人在过自己的生活」

- **NPC 生成器**：菜单生成人形 NPC；**标签驱动人流接通**——NPC 按活动日程（家→公司→吃饭→家）在地图上行走（`PedestrianAgent` 已就绪）。
- **地点表导出修复**：`tools/city_export_activity` 对渋谷的大文件（~65 MB/个）导出卡住待查——小文件秒级完成，需定位是文件规模、appearance 引用还是与编辑器并发的资源锁；修通后 `activity.json` 落地，`MobilityReadiness` 报告人群质量。
- **NPC 可伤害/可击杀**（接 `Damageable`），死亡即移除（gmod 的 NPC 战斗沙盒起点）。
- **验收**：街上 40 个 NPC 按种子确定的日程行走；被攻击会死；帧率达标；无地点表地图上 NPC 优雅降级（站着不动并报告原因）。

## P3 Mod 全面化 —— 「GMod 的灵魂」

- **玩法面全注册点化**：道具、工具、NPC 类型、日程模式全部走 `ModContext` / `ScriptBridge`（Lua mod 与 GDScript mod 同权）。
- **addons 目录约定**：向 GMod 的 `addons/<名>/` 习惯靠拢（清单 + lua/gd 入口），双加载器分工不变。
- **验收**：一个纯 Lua mod 新增一种工具 + 一种道具，且出现在生成菜单与工具枪轮盘里。

## P4 地图与内容 —— 「construct 与城市」

- **gm_construct 风格内置沙盒图**：平坦草地 + 白盒建筑 + 水域，纯代码构建，作为第二 `MapSource`——mod 也可以注册自己的地图。
- **渋谷城市图保留**（城市沙盒 + 人流的展示舞台），含 SDK 可选降级。
- **实体组合存档**：生成/焊接/绳索/复制的世界状态进存档（decision-based：存实体蓝印而非物理状态）。
- **远期（不承诺时间）**：NPC 战斗 AI、载具生成菜单、多人。

---

## 技术决定（不变项）

- **场景在代码里构建**，`.tscn` 只挂脚本；无头测试四件套是唯一合并门槛。
- **模块只经 `Services` / `Events` 通信**；每个玩法面先长出 mod 注册点，再长核心实现。
- **GDExtension 一律 `ClassDB` 探测 + `Variant`**，绝不写进 `project.godot`、绝不写成类型。
- 存档只存「决定」+ `map_id`；世界由地图源重建。
- **MIT 发布**：本项目代码 MIT；第三方资源（godot-plateau、godot-mod-loader 等）保留原许可，见 README 许可表。
