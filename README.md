# Propsmith

**以 MIT 协议发布的沙盒游乐场。** Godot 4.7 · Forward+ · Jolt Physics。

本项目复刻经典沙盒游戏的玩法骨架——物理道具、工具建造、约束系统、NPC 与城市人流、
脚本 Mod 生态——全部为原创实现，不包含任何第三方游戏的代码、模型或资产。
开发路线见 [docs/ROADMAP.md](docs/ROADMAP.md)。

项目当前状态：沙盒基础系统（P0–P4）已全部交付；角色管线（参数化基准模型、
形状键外观编辑、行走动画）、决策日志持久化与联机传输模块已落地。
默认地图为 PLATEAU 渋谷街区，街道人流由建筑用途标签驱动。

---

## 系统需求

- Godot 4.7（stable）
- Windows 10/11（其他平台未经测试）
- 可选：PLATEAU 城市数据（数百 MB/城市，不入库，需单独下载）

## 快速开始

```powershell
# 打开编辑器
& 'D:\GJ\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe' --path 'D:\untitled\FPGames'

# 无头烟雾测试（地图加载、碰撞、Mod 加载）
pwsh -File tools\smoke_test.ps1

# 逐文件语法检查（不启动游戏）
pwsh -File tools\check_scripts.ps1

# 可选脚本运行时（Godot Sandbox / Lua GDExtension）兼容层自检
pwsh -File tools\check_runtimes.ps1
```

**地图数据**需单独下载至 `data/plateau/<城市>/`：

```powershell
python tools\plateau\scan_cities.py --areas 渋谷区 --max-mb 800 --keep --work-dir data\plateau-scan
# 将解压出的「渋谷区」目录移动为 data/plateau/shibuya
```

首次加载默认取 `udx/bldg` 的第一个网格（数千栋建筑）。环境变量：
`DSH_MAP_FILES`（加载数量）、`DSH_MAP_LOD`（1=白模，2=带纹理）、`DSH_MAP_CITY`、
`DSH_MAP_DATA`。

## 操作

| 按键 | 功能 |
|---|---|
| `WASD` / `Shift` / `Ctrl` / `Space` | 移动 / 冲刺 / 蹲下 / 跳跃 |
| `E` | 交互（上车、编辑市民外观等） |
| `左键` | 攻击 / 当前工具主操作 |
| `1` `2` `3` | 工具轮盘持有槽位 |
| `Q` | 生成菜单 |
| `~` | 建造面板 |
| `V` | 角色外观面板（玩家） |
| `F3` / `F1` | 自由视角 / 调试信息 |
| `F5` / `F9` | 快速保存 / 快速读取 |
| `Esc` | 菜单 |

载具：走近载具按 `E` 上车，`WASD` 驾驶，再按 `E` 下车。
市民外观编辑：面对市民按 `E`，面板将切换为该市民的外观编辑模式。

---

## 架构

数据流为单向：**模块只通过服务（`Services`）与事件（`Events`）两条缝通信，互不持有引用**。
这是模块可替换、可删除、可被 Mod 扩展的前提。

```
src/
  boot/startup.gd          应用入口：装载 Mod → 加载地图 → 生成玩家、载具与 UI
  core/
    services.gd            服务容器（模块间唯一解析缝）
    event_bus.gd           类型化事件总线（模块间唯一广播缝）
    decision_log.gd        决策日志：世界变更的唯一出口（应用→日志→广播→自动保存）
    game_state.gd          会话状态与存档数据（只存"决定"，不存可重算状态）
    save_system.gd         JSON 快照存档，模块各自注册序列化节；读档校验地图身份
    mod_host.gd            Mod 的发现、依赖排序与生命周期
    mod_base.gd / mod_context.gd   Mod 契约与 API 门面
    scripting_runtimes.gd  可选脚本 GDExtension 的探测与降级
    scripted_mod.gd / script_bridge.gd   Lua / 沙盒 GDScript Mod 宿主与门面
  map/
    map_source.gd          地图源接口：构建世界、出生点、地图身份
    plateau_map_source.gd  PLATEAU 城市实现：CityGML 加载 + 碰撞 + 标签人流
    plateau_reader.gd      SDK 读取的唯一天花板（加载/展平/属性/量测）
  world/
    surface_query.gd       地表查询服务（物理射线唯一入口）
  player/
    player.gd              角色控制器（移动/体力/蹲下/可被接管）
    camera_rig.gd          第三人称环绕相机
    player_scene.gd        玩家场景的代码组装
    figure_attachment.gd   模型解析链与组件栈附加（任意人形 figure 通用）
    character_appearance.gd / character_appearance_controller.gd
                           Configura 外观的程序化构建、应用与持久化
    model_blend_shapes.gd  形状键滑条目录与每实例应用（含服装零映射同步）
    model_stance.gd        程序化站姿（无动画模型的呼吸/摆臂）
    model_clips.gd         行走剪辑驱动（速度决定播放与步幅）
    freecam.gd             自由视角相机
    interactable.gd / interaction_probe.gd   可交互物契约与朝向探测
  net/
    enet_transport.gd      ENet 联机传输模块（决定广播/追赶/位置中继）
  mobility/                标签驱动人流（NPC 的"一天"）——地图无关
    pedestrian_agent.gd    行人 agent：沿日程行走；外观经由共享基准模型
    npc_figure.gd          市民外观全套（穿衣/参数覆盖/编辑入口/按需渲染）
    npc_figure_editor.gd   市民外观编辑的交互入口
    place_table.gd / activity_tag.gd / activity_pattern.gd
    destination_chooser.gd / route_cache.gd / agent_route.gd / mobility_readiness.gd
  combat/                  伤害契约与参考实现（不做平衡）
  vehicle/                 驾驶模型与上下车
  sandbox/                 道具目录/工厂/生成器/工具/约束/持久化
  ui/
    character_panel.gd     角色外观面板（玩家/市民双模式）
    blend_section.gd       形状键编辑区组件
    hud.gd / pause_menu.gd / building_panel.gd / spawn_menu.gd
addons/plateau/            godot-plateau GDExtension（PLATEAU CityGML 加载）
addons/mod_loader/         GodotModding/godot-mod-loader（zip 式 Mod 加载器）
addons/Configura/          Configura 角色创建框架
addons/vrm/ + addons/Godot-MToon-Shader/   V-Sekai godot-vrm（VRM 1.0 导入）
tools/                     测试四件套、地图工具、模型导出与探针
```

### 关键设计决定

| 决定 | 原因 |
|---|---|
| **场景在代码里构建**，不用 `.tscn` | 结构可作为 diff 审查，不会与脚本漂移，且能被无头测试验证。 |
| **地图源是服务缝（`map_source`）** | 启动流程不知道地图从哪来；Mod 可注册自己的地图，核心零改动。 |
| **`SurfaceQuery` 服务统一回答地表问题** | 物理射线只打地图专用物理层，出生、停车、人流走同一缝。 |
| **PLATEAU SDK 全程 `ClassDB` 探测 + `Variant`** | GDExtension 类名绝不写成类型：SDK 缺席时工程仍可编译。 |
| **战斗只有接口** | `Damageable` 与 `Attacker` 是两个方向的契约；核心只给参考实现。 |
| **存档存"决定"而非"状态"** | 世界由地图源重建，读档校验 `map_id`，不匹配明确拒绝。 |
| **世界变更统一走决策日志** | 离散决定（生成/移除/上色/外观）入 JSONL 日志：崩溃安全、自动保存 O(1)、联机广播与持久化共用同一事件流。快照节承担连续状态与压实点。 |
| **玩家与市民共用同一基准模型** | 一只市民 = 一张种子确定性参数表；形态键权重与服装可见性是每实例状态，不复制模型资源。 |
| **按需渲染三道闸** | 渲染器侧距离剔除（55 m）、阴影纪律（仅躯干与头部投影）、站姿骨骼写入距离门（45 m）——远处市民近乎零成本。 |
| **座位就是一个 `Interactable`** | 上下车复用既有探测/提示/按键链路。 |
| **两套 Mod 加载器按清单文件名分工** | `ModHost` 认 `mod.json`，godot-mod-loader 认 `manifest.json`，互不扫描对方目录。 |

---

## 角色

角色外观基于**共用基准模型** `assets/characters/base_female.vrm`
（VRM 1.0，102 关节，15 网格，行走/待机动画就绪）：

- 形体：九条形状键滑条（纤细/微肉感/丰满、胸部五档、腮红），拖动实时生效，
  服装按形状键同名自动跟随（零映射表同步）。
- 服装：九件可见性开关（夹克/紧身袜/凉鞋/袖套/腿套/腿环/封条/内衣/发夹）。
- 市民：四十名市民共享同一模型，各自持有种子确定的参数表；面向市民按 `E`
  即可进入该市民的外观编辑，改动经决策日志持久化。

角色管线与许可详见 [docs/local](docs/local)（本地笔记，不入库）与下方许可表。

---

## 存档与决策日志

- 快照路径：`user://saves/<slot>.json`，默认槽位 `slot1`。
- 快照内容：`meta` + `state`（地图身份/种子/时间/发现记录/出生点/模块状态）+
  `sections`（各模块自注册的数据节：玩家、外观、沙盒道具、Mod、市民外观覆盖）。
- **离散世界变更以决策日志形式追加**于 `user://journal/<slot>.jsonl`：
  生成/移除/上色/配重/外观覆盖等每一步都可重放；崩溃后重启会自动重放未入快照的尾部。
- **保存即压实**：快照写入后，已被快照覆盖的决策自日志中移除，日志只保留快照
  无法表达的尾部（当前为空）。
- **读档校验 `map_id`**：存档与当前地图不匹配会被拒绝并说明原因。
- 模块通过 `SaveSystem.register_persistent(id, serializer, deserializer)` 接入快照，
  通过 `DecisionLog.register_applier(kind, applier, snapshot_covered)` 接入决策流。

---

## 多人（模块已就绪，界面待接）

联机采用**主机权威**模型：主机运行世界并持有唯一日志写入权，客户端应用主机
下发的决策流，并把自己的决定提交给主机裁决。

- 传输模块 `EnetTransport`（ENet，主机/加入）已实现：决定广播、迟到者追赶
  （沙盒快照 + 未覆盖日志）、玩家位置中继。
- 联机界面（建主机/加入/房间列表）尚未接入；当前可经由代码或探针启用。
- 远端玩家当前以占位头像渲染；共享基准模型的完整外观同步在路线中。

---

## Mod 支持

见 [docs/MODDING.md](docs/MODDING.md)。最小例子：

```
res://mods/my_mod/
    mod.json     # { "id": "my_mod", "name": "我的 Mod" }
    mod.gd       # extends ModBase
```

示例 Mod `mods/lighthouse/` 演示世界注入、物品、战斗与自存档；`mods/garage/`
演示新增一种载具。Lua / 沙盒 GDScript 写法见
[docs/SCRIPTED_MODS.md](docs/SCRIPTED_MODS.md)。

### 两套加载器，各管一半

| 加载器 | 认的清单 | 认的入口 | 管什么 |
|---|---|---|---|
| 本项目 `ModHost` | `mod.json` | `mods/<id>/mod.gd`（或 `mod.lua` / `mod.sgd`） | 与游戏架构深度集成的**内容 Mod**：走服务、事件与扩展点 |
| [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader) | `manifest.json` | `res://mods` 里的 `.zip`、`res://mods-unpacked/<id>/` | 社区标准件：不需要游戏源码即可**改写脚本/场景/资源**、Mod 配置与档案 |

两者靠**清单文件名**分工，互不扫描对方的目录，因此可以共存而无需适配代码。

---

## 已知边界

- 战斗只有接口与参考实现，**没有**敌人 AI、伤害数字、连招或平衡。
- **人流**：地点表导出工具对渋谷的大数据集（~65 MB/文件）卡住待查——当前默认
  无地点表，街上没有人，boot 报告会说明；小地图导出正常。
- 默认加载 LOD1 白模（无纹理）；`DSH_MAP_LOD=2` 可看带纹理的 LOD2。
- **地面是平的**：城市 DEM 地形尚未接入，坡地建筑底部会悬浮。
- 建筑碰撞由 SDK 的 `generate_collision` 一把生成；分块流式是后续项。
- **多人**：传输模块已就绪并经双进程探针验证，但缺少联机界面与远端玩家的
  完整外观同步；45/55 m 的按需渲染阈值待实机校准。
- **物品是预留扩展点**：注册与校验就绪，核心还没有库存/拾取/掉落系统去消费它。
- Godot Sandbox / Lua GDExtension 默认测试环境未安装；探测与降级路径由
  `tools/check_runtimes.ps1` 覆盖。

---

## 许可

本项目以 **MIT 协议**发布，全文见 [LICENSE](LICENSE)。

随工程分发的第三方资源保留各自的原始许可，**不受**本项目 MIT 协议覆盖：

| 资源 | 许可 | 位置 |
|---|---|---|
| [godot-plateau](https://github.com/shiena/godot-plateau) PLATEAU 加载 GDExtension | MIT | `addons/plateau/`（版权归 Shiena 及贡献者） |
| [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader) Mod 加载器 | CC0 1.0 | `addons/mod_loader/LICENSE`（版权归 GodotModding 及贡献者） |
| [JSON_Schema_Validator](https://github.com/GodotModding/godot-mod-loader)（上者的依赖） | MIT | `addons/JSON_Schema_Validator/JSON_Schema_validator_LICENSE`（版权归 Sahedo） |
| [Configura](https://github.com/Team-Figoose/Configura) 角色创建框架 | MIT | `addons/Configura/LICENSE.txt`（版权归 Configura Team） |
| [godot-vrm](https://github.com/V-Sekai/godot-vrm) VRM 导入/导出 | MIT | `addons/vrm/LICENSE`（版权归 V-Sekai Contributors 及 VRM Consortium） |
| [Godot-MToon-Shader](https://github.com/V-Sekai/godot-vrm)（上者的 VRM 动漫画着色器，同一仓库内） | MIT | `addons/Godot-MToon-Shader/LICENSE` |
| [Godette VRM 示例模型](https://github.com/SirRichard94/low-poly-godette) | CC-BY 3.0 | `vrm_samples/Godette_vrm_v4.vrm` 与 `vrm_samples/LICENSE_SAMPLES.txt`（模型版权归 SirRichard94，VRM 适配归 Lyuma） |
| [SiroinoSotai（しろいの素体）](https://booth.pm/ja/items/8268676) 基准模型的**躯干**（16.7k 三角 · Mobile 版 3.5k · 99 个形态键） | **CC0 1.0 全世界**（商用/修改/再分发皆可，**无需署名**） | 原始包与 PSD 不入库（在 `vendor/models/`，gitignore） |
| [茜犬-Akane-](https://booth.pm/ja/items/8861598)（山野重工赤山派閥独立支部）基准模型的**头部**与**基色贴图** | **CC0 1.0 全世界**，作者并将**角色设计的著作权**一并声明适用 CC0 | 与上者合成为 `assets/characters/base_female.vrm`（原始包与 PSD 不入库） |
| [Godot4-OpenAnimationLibraries](https://github.com/catprisbrey/Godot4-OpenAnimationLibraries)（catprisbrey）**行走动画**来源：其 ShooterLib 的 `walk` / `idle` / `run_067` 经骨骼重定向进入 `assets/animations/locomotion.res`（构建脚本 `tools/models/build_locomotion_library.gd`） | **CC-BY 4.0**（须署名——本行即署名） | 仅保留三个剪辑的重定向副本（81 KB）；原库 2.9 MB 不入库 |

`assets/characters/base_female.vrm` 是上两行作者成果的**合成**：SiroinoSotai 的
躯干 + Akane 的头部与基色贴图，由 `tools/models/export_akane_vrm.py` 从 FBX
导出为 VRM 1.0。

### SiroinoSotai 的例外与禁忌

来自商品页，与 CC0 并列且必须遵守：

- **Logo 数据不在 CC0 范围内**：仅可用于标示"符合 SiroinoSotai 対応 标准"的作品，
  且不得改动文字、标记、配色与纵横比。
- **UnityPackage 所引用的第三方数据**（VRChat SDK、lilToon 等）**不包含在该商品内，
  也不适用 CC0**——本项目不经过 Unity，故不涉及。
- **表记禁忌**：不得使用「公式」「公認」「認定」「監修」「共同開発」等可能让人误认为
  SiroinoSotai 运营方参与制作/品质确认/销售的表述。
- 署名非义务，出于礼貌记录：企画・制作 しろいの ／ 協力 ちゃかぽ 様 ／ ウェイト制作 せらすずな 様。

### 茜犬-Akane- 的例外与禁忌

其许可是**基于素体的 CC0** 声明（页面对本商品收录的全部数据——三个版本的 FBX、
.blend、PNG/PSD、UnityPackage、.VRM，以及**角色设计本身的著作权**——统一适用
CC0 1.0），并写明「**利用規約はありません**」。因此上一条 SiroinoSotai 的
**Logo 例外、第三方（VRChat SDK、lilToon）例外与表记禁忌同样适用**；此外作者声明
本项目不提供说明书与支持。

### 曾经评估、但未随工程分发的角色管线（负面结论同样留痕）

- **Hamr + MB-Lab**：可参数化生成 VRM，但 MB-Lab 的 `license.txt` 声明「生成的模型
  默认沿用 AGPL-3，作为 AGPL 数据库的衍生品必须同样以 AGPL-3 分发」——与本项目的
  MIT 不兼容。**该管线已放弃，任何产出均已从仓库与历史中移除**。
- **VRoid Studio**：模型本身可商用、可用于游戏，但其 Guidelines 限制「制作能生成或
  输出由 VRoid 网格变形/组合而成的形象的应用」需 pixiv 单独授权（仅自用豁免），
  与"公开产品内置捏人"冲突。**未采用**。
- **SMPL**：许可明确禁止商用（"non-commercial…any other use, in particular any use
  for commercial purposes, is prohibited…video games"），**不可用于本项目**。

游戏内容所用的 **PLATEAU 城市数据不入库**（下载到 `data/`，已 gitignore），其许可为
政府標準利用規約（第 2.0 版）/ CC BY 4.0 / ODC BY / ODbL；对外发布使用了数据的
作品时需要署名「国土交通省 PLATEAU」。
