# FPGames

**受 Garry's Mod 启发、以 MIT 协议发布**的沙盒游乐场。Godot 4.7 / Forward+ / Jolt Physics。

复刻的是 GMod 的玩法骨架——**沙盒物理、工具枪、NPC 与人流、Lua 式 mod 生态**——
不使用任何 Valve/GMod 的代码、模型或资产。开发路线见 [docs/ROADMAP.md](docs/ROADMAP.md)。

当前状态：沙盒底座（物理 / 载具 / 战斗接口 / 城市地图）已就绪；工具枪与生成菜单在
P0/P1（见路线图）。默认地图是 PLATEAU 渋谷街区，街上的人流由地图自身的用途标签驱动。

---

## 快速开始

```powershell
# 打开编辑器
& 'D:\GJ\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe' --path 'D:\untitled\FPGames'

# 无头烟雾测试（含地图加载、碰撞、mod 加载）
pwsh -File tools\smoke_test.ps1

# 逐文件语法检查（不启动游戏）
pwsh -File tools\check_scripts.ps1

# 可选脚本运行时（Godot Sandbox / Lua GDExtension）兼容层自检
pwsh -File tools\check_runtimes.ps1
```

**地图数据**（数百 MB/城市，不入库）需要单独下载到 `data/plateau/<城市>/`：

```powershell
python tools\plateau\scan_cities.py --areas 渋谷区 --max-mb 800 --keep --work-dir data\plateau-scan
# 然后把解压出的「渋谷区」目录移动为 data/plateau/shibuya
```

首次加载默认取 `udx/bldg` 的第 1 个网格方块（数千栋建筑）。环境变量可调：
`DSH_MAP_FILES`（加载数量）、`DSH_MAP_LOD`（1=白模，2=带纹理）、`DSH_MAP_CITY`、`DSH_MAP_DATA`。

操作：`WASD` 移动 · `Shift` 冲刺 · `Ctrl` 蹲下 · `Space` 跳跃 · `E` 交互 ·
`左键` 攻击 · `F3` 自由视角 · `F1` 调试信息 · `F5` 快速保存 · `F9` 快速读取 ·
`M` 地图（预留）· `Esc` 菜单。

载具：走到车旁按 `E` 上车，`WASD` 驾驶，再按 `E` 下车。

---

## 架构

数据流是单向的：**模块只通过服务与事件通信，互不持有引用**。这是模块可替换、
可删除、可被 mod 扩展的前提。

```
src/
  boot/startup.gd        应用入口：装载 mod → 加载地图 → 生成玩家、载具与 UI
  core/
    services.gd          服务容器（模块间的唯一解析缝）
    event_bus.gd         类型化事件总线（模块间的唯一广播缝）
    game_state.gd        会话状态与存档数据（只存"决定"，不存可重算的东西）
    save_system.gd       JSON 存档，模块各自注册序列化器；读档校验地图身份
    mod_host.gd          本项目 mod 的发现、依赖排序、生命周期
    mod_base.gd          mod 基类（扩展点契约）
    mod_context.gd       mod 可触碰的 API 门面
    scripting_runtimes.gd  可选脚本 GDExtension 的探测、状态与安装指引
    scripted_mod.gd      以 Lua / SafeGDScript 写成的 mod 的宿主
    script_bridge.gd     交给外部语言的注册门面（兼容层的契约本体）
  map/
    map_source.gd        地图源接口：构建世界、出生点、地图身份
    plateau_map_source.gd PLATEAU 城市实现：CityGML 加载 + 碰撞 + 地点表人流
    plateau_reader.gd    SDK 读取的唯一天花板（加载/展平/属性/量测）
  world/
    surface_query.gd     地表查询服务（物理射线；唯一被允许"问地面"的地方）
  player/
    player.gd            角色控制器（移动/体力/重力/蹲下/可被"接管"）
    camera_rig.gd        第三人称环绕相机
    player_scene.gd      玩家场景的代码构建
    freecam.gd           自由视角相机（F3，可调飞行档位）
    interactable.gd      可交互物契约
    interaction_probe.gd 朝向感知的交互探测
  vehicle/
    vehicle.gd           驾驶模型 + 上下车（接管/归还角色）
    vehicle_seat.gd      座位就是一个普通 Interactable（上车＝交互）
    vehicle_scene.gd     载具场景的代码构建
    vehicle_system.gd    载具服务：挑选平地停放本局车队
  mobility/              标签驱动人流（NPC 的"一天"）——地图无关
    place_table.gd       导出的地点表 → 路由候选
    pedestrian_agent.gd  行人 agent：沿日程走、贴墙滑行
    activity_tag.gd      规范活动标签 + 别名表（＝地图来源适配器）+ 回退阶梯
    activity_pattern.gd  一天的活动序列（家→公司→饭店→公司→家）
    destination_chooser.gd  按 标签 + 距离/权重 选具体地点
    route_cache.gd       路线缓存：共享、有界、换地图版本必须失效
    agent_route.gd       模式 → 具体地点；创建时解析目的地，逐段懒加载路径
    mobility_readiness.gd  地图能否启用人流：可选能力报告
  combat/                只提供接口 + 参考实现，不做平衡
    damage_info.gd       一次伤害事件（数据）
    damageable.gd        "可被伤害"契约
    attacker.gd          "可造成伤害"契约
    attack_data.gd       攻击参数（Resource）
    hitbox.gd / hurtbox.gd
    health_component.gd  参考伤害实现（血量/无敌帧/死亡）
    basic_melee_weapon.gd 参考攻击实现
    mod_integration.gd   把 mod 注册的战斗提供者接进游戏
  ui/
    loading_screen.gd    启动进度（纯观察者）
    hud.gd               准星/提示/通知/体力/小地图/调试
    pause_menu.gd        暂停、存读档、返回出生点、mod 列表
mods/lighthouse/         示例 mod（世界注入、物品、战斗、自存档）
mods/garage/             示例 mod（新增一种载具）
mods-unpacked/           godot-mod-loader 的解包 mod 目录（见下）
examples/scripted_mods/  Lua / SafeGDScript mod 范例（需另装 GDExtension）
addons/plateau/          godot-plateau GDExtension（PLATEAU CityGML 加载）
addons/mod_loader/       GodotModding/godot-mod-loader（zip 式 mod 加载器）
tools/plateau/           数据扫描 / 下载 / 标签覆盖率分析（scan_cities、inspect_gml）
tools/                   check_scripts / smoke_test / check_runtimes / 截图与诊断探针
```

### 关键设计决定

| 决定 | 原因 |
|---|---|
| **场景在代码里构建**，不用 `.tscn` | 结构可作为 diff 审查，不会与脚本漂移，且能被无头测试验证。`startup.tscn` 只挂一个脚本。 |
| **地图源是服务缝（`map_source`）** | 启动流程不知道地图从哪来；mod 或未来实现可以注册自己的地图，核心其余部分零改动。 |
| **`SurfaceQuery` 服务统一回答地表问题** | 物理射线只打地图专用物理层，玩家出生、停车选址、人流都走同一缝。 |
| **PLATEAU SDK 全程 `ClassDB` 探测 + `Variant`** | GDExtension 类名绝不写成类型：SDK 缺席时工程仍可编译，失败是可诊断的运行时错误。 |
| **战斗只有接口** | `Damageable` 与 `Attacker` 是两个方向的契约；核心只给参考实现，规则由游戏或 mod 提供。 |
| **存档存"决定"而非"状态"** | 发现记录与模块自注册的数据段之外，世界身份是 `map_id`：读档校验，不匹配明确拒绝。 |
| **人流是可选能力** | `MobilityReadiness` 回答"这张地图能否启用人流、为什么不能"——没有标签的地图不是坏地图，只是这项功能不开。 |
| **座位就是一个 `Interactable`** | 上下车复用已有的探测/提示/按键链路，所以「加一种载具」在玩家、HUD、输入映射里各占 0 行。 |
| **两套 mod 加载器按清单文件名分工** | 本项目的 `ModHost` 认 `mod.json`，`godot-mod-loader` 认 `manifest.json`。互不扫描对方的目录，因此可以同时存在而无需适配代码。 |

---

## 地图：PLATEAU 渋谷（含人流）

默认地图从 **PLATEAU**（日本国土交通省 MLIT 的全国 3D 都市模型）加载，城市选**渋谷区**
（90,544 栋建筑，`bldg:usage` 用途标签 100% 覆盖）。

- 数据格式 CityGML（EPSG:6697 / JGD2011 第 9 区），经社区 GDExtension
  **[`shiena/godot-plateau`](https://github.com/shiena/godot-plateau)**（MIT）加载；
  SDK 全程 `ClassDB` 探测、可整体替换。
- **人流管线**：`tools/city_export_activity` 从数据导出**地点表**（每栋建筑 → 规范活动标签 +
  位置）→ `MobilityReadiness` 判定能否启用 → 行人 agent 按种子确定的日程（家→公司→饭堂→家）
  在街上行走，`move_and_slide` 贴墙滑行不穿楼。没有地点表的地图优雅降级并在 boot 报告说明。
- 许可：**政府標準利用規約 / CC BY 4.0 / ODbL** 等多许可，允许商用；对外发布使用了数据的
  作品需要署名「国土交通省 PLATEAU」。

---

## 存档

- 路径：`user://saves/<slot>.json`，默认槽位 `slot1`。
- 内容：`meta` + `state`（地图身份/种子/时间/发现记录/出生点/模块状态）+ `sections`（各模块自注册的数据）。
- **读档校验 `map_id`**：存档与当前地图不匹配会被拒绝并说明原因。
- 模块通过 `SaveSystem.register_persistent(id, serializer, deserializer)` 接入，
  **不需要**改核心存档格式。

---

## Mod 支持

GMod 式沙盒的灵魂。见 [docs/MODDING.md](docs/MODDING.md)。最小例子：

```
res://mods/my_mod/
    mod.json     # { "id": "my_mod", "name": "我的 Mod" }
    mod.gd       # extends ModBase
```

示例 mod `mods/lighthouse/` 演示世界注入（在地图就绪后放一座会转灯的灯塔）、物品、战斗与自存档；
`mods/garage/` 演示新增一种载具。Lua / 沙盒 GDScript 写法见
[docs/SCRIPTED_MODS.md](docs/SCRIPTED_MODS.md)。

### 两套加载器，各管一半

| 加载器 | 认的清单 | 认的入口 | 管什么 |
|---|---|---|---|
| 本项目 `ModHost` | `mod.json` | `mods/<id>/mod.gd`（或 `mod.lua` / `mod.sgd`） | 与游戏架构深度集成的**内容 mod**：走服务、事件与扩展点 |
| [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader) | `manifest.json` | `res://mods` 里的 `.zip`、`res://mods-unpacked/<id>/` | 社区标准件：不需要游戏源码即可**改写脚本/场景/资源**、mod 配置与档案 |

两者靠**清单文件名**分工，互不扫描对方的目录，因此可以共存而无需适配代码。

---

## 已知边界

- 战斗只有接口与参考实现，**没有**敌人 AI、伤害数字、连招或平衡。
- **人流**：核心与行人 agent 已接通，但渋谷的地点表导出工具对大数据集（~65 MB/文件）
  卡住待查（见路线图 P2）——当前默认无地点表，街上没有人，boot 报告会说明。
- 默认加载 LOD1 白模（无纹理）；`DSH_MAP_LOD=2` 可看带纹理的 LOD2。
- **地面是平的**：城市 DEM 地形尚未接入，坡地建筑底部会悬浮。
- 建筑碰撞用 SDK 的 `generate_collision` 一把生成；分块流式是后续项。
- **载具只有一辆皮卡加一个 mod 范例**，不参与存档。
- **物品是预留扩展点**：注册与校验就绪，但核心还没有库存/拾取/掉落系统去消费它。
- Godot Sandbox / Lua GDExtension 默认测试环境未安装；探测与降级路径由
  `tools/check_runtimes.ps1` 覆盖。

---

## 许可

本项目以 **MIT 协议**发布，全文见 [LICENSE](LICENSE)。

随工程分发的第三方资源保留各自的原始许可，**不受**本项目 MIT 协议覆盖：

| 资源 | 许可 | 位置 |
|---|---|---|
| [godot-plateau](https://github.com/shiena/godot-plateau) PLATEAU 加载 GDExtension | MIT | `addons/plateau/`（版权归 Shiena 及贡献者） |
| [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader) mod 加载器 | CC0 1.0 | `addons/mod_loader/LICENSE`（版权归 GodotModding 及贡献者） |
| [JSON_Schema_Validator](https://github.com/GodotModding/godot-mod-loader)（上者的依赖） | MIT | `addons/JSON_Schema_Validator/JSON_Schema_validator_LICENSE`（版权归 Sahedo） |

游戏内容所用的 **PLATEAU 城市数据不入库**（下载到 `data/`，已 gitignore），其许可为
政府標準利用規約（第 2.0 版）/ CC BY 4.0 / ODC BY / ODbL；对外发布使用了数据的作品时需要
署名「国土交通省 PLATEAU」。
