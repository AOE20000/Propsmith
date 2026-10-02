# FPGames

小型开放世界原型：Godot 4.7 / Forward+ / Jolt Physics。
核心是**探索**，战斗只提供**稳定接口**（不含平衡），支持 **mod** 扩展。

---

## 快速开始

```powershell
# 打开编辑器
& 'D:\GJ\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe' --path 'D:\untitled\FPGames'

# 无头烟雾测试（含地形生成、碰撞、mod 加载）
pwsh -File tools\smoke_test.ps1

# 逐文件语法检查（不启动游戏）
pwsh -File tools\check_scripts.ps1

# 可选脚本运行时（Godot Sandbox / Lua GDExtension）兼容层自检
pwsh -File tools\check_runtimes.ps1
```

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
  boot/startup.gd        应用入口：装载 mod → 构建世界 → 生成玩家、载具与 UI
  core/
    services.gd          服务容器（模块间的唯一解析缝）
    event_bus.gd         类型化事件总线（模块间的唯一广播缝）
    game_state.gd        会话状态与存档数据（只存"决定"，不存可重算的东西）
    save_system.gd       JSON 存档，模块各自注册序列化器
    mod_host.gd          本项目 mod 的发现、依赖排序、生命周期
    mod_base.gd          mod 基类（扩展点契约）
    mod_context.gd       mod 可触碰的 API 门面
    scripting_runtimes.gd  可选脚本 GDExtension 的探测、状态与安装指引
    scripted_mod.gd      以 Lua / SafeGDScript 写成的 mod 的宿主
    script_bridge.gd     交给外部语言的注册门面（兼容层的契约本体）
  world/
    world_builder.gd     阶段编排：地形 → 环境 → mod → 散布 → 地标 → mod
    terrain_config.gd    岛屿形状参数（Resource，可被 mod 替换）
    terrain_generator.gd 噪声分层 + Terrain3D 填充 + CPU 高度场
    terrain_query.gd     地表查询服务（唯一被允许"问地面"的地方）
    environment.gd       天空/太阳/雾/海面（含昼夜循环）
    world_scatter.gd     确定性散布（抖动网格 + MultiMesh）
    prop_factory.gd      程序化植被网格 + 顶点色材质
    poi_marker.gd        可发现地标（含四种程序化几何）
    poi_placer.gd        地标选址与放置
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
  mobility/              地图无关的城市人类移动（只认"被标注过的地点"）
    activity_tag.gd      规范活动标签 + 别名表（＝地图来源适配器）+ 回退阶梯
    activity_pattern.gd  一天的活动序列（家→公司→饭店→公司→家）
    destination_chooser.gd  按 标签 + 距离/权重 选具体地点
    route_cache.gd       路线缓存：共享、有界、换地图版本必须失效
    agent_route.gd       模式 → 具体地点；创建时解析目的地，逐段懒加载路径
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
mods/lighthouse/         示例 mod（地形、散布、地标、物品、战斗）
mods/garage/             示例 mod（新增一种载具）
mods-unpacked/           godot-mod-loader 的解包 mod 目录（见下）
examples/scripted_mods/  Lua / SafeGDScript mod 范例（需另装 GDExtension）
addons/terrain_3d/       Terrain3D 地形后端
addons/mod_loader/       GodotModding/godot-mod-loader（zip 式 mod 加载器）
tools/                   check_scripts / smoke_test / check_runtimes
```

### 关键设计决定

| 决定 | 原因 |
|---|---|
| **场景在代码里构建**，不用 `.tscn` | 结构可作为 diff 审查，不会与脚本漂移，且能被无头测试验证。`startup.tscn` 只挂一个脚本。 |
| **地形后端通过 `ClassDB` 按名实例化** | Terrain3D 是 GDExtension。这样即使卸载插件，工程依然可加载、可校验，地形后端可整体替换。 |
| **`TerrainQuery` 服务统一回答地表问题** | 玩家出生、散布、地标选址、mod 都走同一缝；换地形实现不影响调用方。 |
| **散布用抖动网格而非拒绝采样** | 密度是"米间距"这种可推理的量，同种子必定复现，且不会因随机失败而出现空洞。 |
| **一个道具 = 一个带顶点色的网格** | 一个 `MultiMeshInstance3D` 就能承载上千实例、一次绘制。顶点色 G 通道在树干/树冠之间混色。 |
| **战斗只有接口** | `Damageable` 与 `Attacker` 是两个方向的契约；核心只给参考实现，规则由游戏或 mod 提供。 |
| **存档存"决定"而非"状态"** | 世界由种子确定重生成，所以存档里只有一个整数种子，加上发现记录与各模块自注册的数据段。 |
| **角色可以被"接管"** | 上车与自由视角都要夺走角色的控制权。做法是 `Player.take_control()` 挂起自身的移动/重力并关掉碰撞体，而不是把角色 reparent 进载具——那样两个碰撞体会互相推挤。 |
| **座位就是一个 `Interactable`** | 上下车复用已有的探测/提示/按键链路，所以「加一种载具」在玩家、HUD、输入映射里各占 0 行。 |
| **两套 mod 加载器按清单文件名分工** | 本项目的 `ModHost` 认 `mod.json`，`godot-mod-loader` 认 `manifest.json`。互不扫描对方的目录，因此可以同时存在而不需要任何适配代码。 |

### 从 godot-3d-sandbox 移植了什么

本源码来自 [craftablescience/godot-3d-sandbox](https://github.com/craftablescience/godot-3d-sandbox)，
一个 GMod 风格的 3D 试验场（Godot 3.1.2，2019）。它只有 348 行，但其中
**驾驶载具 + 上下车**这一块是本项目完全没有的能力，所以按"玩法保留、API 重写"移植：

| 源项目 | 本项目 | 为什么重写 |
|---|---|---|
| `Pickup.gd` 的油门/刹车/倒车/方向盘缓动 | `src/vehicle/vehicle.gd` | Godot 3 的 `VehicleBody` → `VehicleBody3D`；数值按 1.1 t 车身重新标定 |
| `World.gd` 把玩家 reparent 进车厢 | `Player.take_control()` + 座位吸附 | reparent 会让 `CharacterBody3D` 与载具刚体争夺同一个变换，抖动甚至弹飞 |
| `Freecam.gd` 每帧平移固定距离 | `src/player/freecam.gd`，按 `delta` 缩放 | 原版在 120 Hz 下只有一半速度 |
| `Player.gd` 走/跑/蹲三档 | `player.gd` 的 `walk/sprint/crouch` | 保留为三档，但蹲下做成**姿势**（缩短碰撞体 + 降相机 + 头顶净空检测） |

**刻意没有移植**：主菜单与场景切换（本项目直接进世界，且无头测试依赖这条路径）、
`ui_exit` 退出键（现由 `Esc` 菜单承担）、原项目的 `.glb`/字体/HDR 资源
（本项目一切几何都在代码里生成）。

### 可选脚本运行时

项目**不依赖**任何脚本 GDExtension，同时为其中两个保留了正式的接入点：

- [Godot Sandbox](https://github.com/libriscv/godot-sandbox)（SafeGDScript / 沙盒 C++、Rust）
- [Lua GDExtension](https://github.com/gilzoide/lua-gdextension)（Lua 5.4 / LuaJIT）

判定靠运行时 `ClassDB` 探测，而不是写进 `project.godot`——写进去就等于让它成为硬依赖，
扩展缺失时工程会直接加载失败。两者都没装时，mod 目录里出现 `mod.lua` / `mod.sgd`
会被判为**加载失败并给出安装指引**，而不是抛一个看不懂的解析错误。
写法见 [docs/SCRIPTED_MODS.md](docs/SCRIPTED_MODS.md)，自检见 `tools/check_runtimes.ps1`。

---

## 世界生成

`TerrainConfig` 控制形状（`res://src/world/terrain_config.gd`）：

| 参数 | 默认 | 含义 |
|---|---|---|
| `seed` | 20260930 | 所有噪声层的种子，决定整座岛 |
| `island_radius` | 420 m | 陆地半径 |
| `max_height` | 48 m | 最高海拔 |
| `continent_weight` / `hill_weight` / `mountain_weight` | .62/.28/.10 | 大陆 / 丘陵 / 山脊的占比 |
| `height_curve` | 1.25 | 低地压平、山峰保留 |
| `sample_step` | 2 m | CPU 高度场采样步长 |
| `region_size` | 256 | Terrain3D 区域像素尺寸 |
| `vertex_spacing` | 1 m | 顶点间距 |

生成是**种子确定性**的：同一 `seed` 必定得到同一座岛，同一批植被位置，同一组地标。

实测剖面（种子 20260930，中心向外）：`0m:17.7 → 120m:20.5 → 260m:10.8 → 400m:1.1`。

---

## 计划中：城市地图（地图层尚未实现；移动核心已实现）

下一步打算把默认地图换成 **PLATEAU**（日本国土交通省 MLIT 的全国 3D 都市模型）构建的真实城市
街区，并让城市里的人流由**地图自身的语义**驱动。完整开发计划（数据选型、许可合规、管线、
架构改动、里程碑、风险）见 [docs/CITY_MAP_PLAN.md](docs/CITY_MAP_PLAN.md)。

一句话摘要：地图用 **PLATEAU**（CityGML，**CC BY 4.0 / 政府標準利用規約**，约 250+ 城市，
允许商用），Godot 侧用社区 GDExtension **[`shiena/godot-plateau`](https://github.com/shiena/godot-plateau)**
（MIT，带 LOD 自动切换与动态瓦片，含**路网 API**）。**不使用任何真实轨迹数据**：
人流由地图的标签驱动，"人一天怎么走"由活动模式表达。范围是**街区优先 2–3 km² + 架构预留流式**。

**M0 已完成**（结论见计划里的"M0 结论"一节）：

- ✅ **SDK 在 Godot 4.7.2 上可用**（38 个类零错误注册；真实 CityGML 解析 102 ms、
  建场景 32 ms；坐标与轴序正确）——原先最大的未知已解除。
- ❌ **但 `bldg:usage`（用途）不是通用属性**：实测某自治体 24,418 栋建筑里出现 **0 次**。
  标签来源因此改为**适配器链**（`bldg:usage` → 用途地域 `urf:function` → 手工/mod 标注），
  且**城市选择要过"标签覆盖率"门槛**（用 `tools/plateau/inspect_gml.py` 出报告）。
- 三个数据坑已记录：**属性键是小写的**（照 SDK 文档的驼峰写法会静默取不到）、
  **`9999`/`0001` 是"未知"哨兵**（实测占约 46%）、**`get_latitude()` 不可信**。

> 这一节描述的是**计划与已完成的可行性验证**，城市地图本身尚未实现——当前默认地图仍是
> 程序化生成的岛屿。但**地图无关的移动核心已经写好并通过断言**（`src/mobility/`，68 条）：
> 它只认"被标注过的地点"，因此换城市、换语言、甚至换成手工标注的地图都不需要改行为层。

---

## 存档

- 路径：`user://saves/<slot>.json`，默认槽位 `slot1`。
- 内容：`meta` + `state`（种子/时间/发现记录/出生点/模块状态）+ `sections`（各模块自注册的数据）。
- 模块通过 `SaveSystem.register_persistent(id, serializer, deserializer)` 接入，
  **不需要**改核心存档格式；模块被删掉后旧存档依然可读（缺失的 section 会被跳过）。

---

## Mod 支持

见 [docs/MODDING.md](docs/MODDING.md)。最小例子：

```
res://mods/my_mod/
    mod.json     # { "id": "my_mod", "name": "我的 Mod" }
    mod.gd       # extends ModBase
```

示例 mod `mods/lighthouse/` 演示了地形、散布、地标、物品、战斗、事件与自存档；
`mods/garage/` 演示新增一种载具。

### 两套加载器，各管一半

| 加载器 | 认的清单 | 认的入口 | 管什么 |
|---|---|---|---|
| 本项目 `ModHost` | `mod.json` | `mods/<id>/mod.gd`（或 `mod.lua` / `mod.sgd`） | 与游戏架构深度集成的**内容 mod**：走服务、事件与扩展点 |
| [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader) | `manifest.json` | `res://mods` 里的 `.zip`、`res://mods-unpacked/<id>/` | 社区标准件：不需要游戏源码即可**改写脚本/场景/资源**、mod 配置与档案 |

两者靠**清单文件名**分工，互不扫描对方的目录，因此可以共存而无需适配代码。
唯一需要留意的是 `godot-mod-loader` 要求自己占用 autoload 的前两位，所以本项目的
加载器叫 `ModHost`，`ModLoader` 这个名字让给了它。

### 用别的语言写 mod

`mod.lua`（Lua GDExtension）与 `mod.sgd` / `mod.elf`（Godot Sandbox）是
`mod.gd` 之外的合法入口，两种语言拿到的是同一个注册门面。
详见 [docs/SCRIPTED_MODS.md](docs/SCRIPTED_MODS.md)。

---

## 已知边界

- 战斗只有接口与参考实现，**没有**敌人 AI、伤害数字、连招或平衡。
- `M` 地图键已注册但大地图界面尚未实现；小地图（右上角俯视）可用。
- 海面是着色器平面，没有水下玩法与游泳。
- 散布的岩石/树没有 LOD；小地图尺寸下这是刻意的取舍。
- 地形使用 Terrain3D 的默认材质；未做贴图绘制管线，只做了高度分层的控制图。
- **载具只有一辆皮卡加一个 mod 范例**，且不参与存档：车辆的位姿像地形和散布一样
  由世界重新生成，而不是被存下来。车辆没有 LOD、没有音效，也没有轮胎转动动画。
- **自由视角是调试工具**，不是玩法：它不保存、不接受被 mod 扩展。
- Godot Sandbox / Lua GDExtension 的**运行绑定按各自公开 API 编写，但默认测试环境
  里两者都未安装**，因此那两条路径只在装了扩展的机器上才会被真正执行；
  探测与降级路径由 `tools/check_runtimes.ps1` 覆盖。
- **物品是预留扩展点**：`add_item_definition` 能注册也会校验，采集事件与存档字段都已
  就绪，但核心还没有库存/拾取/掉落系统去消费它，所以注册物品目前没有可见效果。
  HUD 调试行的「采集种类」因此恒为 0。

---

## 许可

本项目以 **MIT 协议**发布，全文见 [LICENSE](LICENSE)。

随工程分发的第三方资源保留各自的原始许可，**不受**本项目 MIT 协议覆盖：

| 资源 | 许可 | 位置 |
|---|---|---|
| [Terrain3D](https://github.com/TokisanGames/Terrain3D) 地形插件 | MIT | `addons/terrain_3d/LICENSE.txt`（版权归 Cory Petkovsek、Roope Palmroos 及贡献者） |
| [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader) mod 加载器 | CC0 1.0 | `addons/mod_loader/LICENSE`（版权归 GodotModding 及贡献者） |
| [JSON_Schema_Validator](https://github.com/GodotModding/godot-mod-loader)（上者的依赖） | MIT | `addons/JSON_Schema_Validator/JSON_Schema_validator_LICENSE`（版权归 Sahedo） |
| [ambientCG](https://ambientcg.com) 地形贴图：Ground037 / Rock023 / Rock030 | CC0 1.0 | `assets/terrain/textures/asset_licenses.txt` |

CC0 属公有领域，无需署名；这里列出仅为来源可追溯。

载具与自由视角的**玩法来源**是 [craftablescience/godot-3d-sandbox](https://github.com/craftablescience/godot-3d-sandbox)（MIT）：
只借用设计，未复制其代码或资源，全部按 Godot 4 API 重写。
