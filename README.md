# LSPgodot

小型开放世界原型：Godot 4.7 / Forward+ / Jolt Physics。
核心是**探索**，战斗只提供**稳定接口**（不含平衡），支持 **mod** 扩展。

---

## 快速开始

```powershell
# 打开编辑器
& 'D:\GJ\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe' --path 'D:\untitled\ls-pgodot'

# 无头烟雾测试（含地形生成、碰撞、mod 加载）
pwsh -File tools\smoke_test.ps1

# 逐文件语法检查（不启动游戏）
pwsh -File tools\check_scripts.ps1
```

操作：`WASD` 移动 · `Shift` 冲刺 · `Space` 跳跃 · `E` 交互 · `左键` 攻击 ·
`M` 地图（预留）· `Esc` 菜单 · `F1` 调试信息 · `F5` 快速保存 · `F9` 快速读取。

---

## 架构

数据流是单向的：**模块只通过服务与事件通信，互不持有引用**。这是模块可替换、
可删除、可被 mod 扩展的前提。

```
src/
  boot/startup.gd        应用入口：装载 mod → 构建世界 → 生成玩家与 UI
  core/
    services.gd          服务容器（模块间的唯一解析缝）
    event_bus.gd         类型化事件总线（模块间的唯一广播缝）
    game_state.gd        会话状态与存档数据（只存"决定"，不存可重算的东西）
    save_system.gd       JSON 存档，模块各自注册序列化器
    mod_loader.gd        mod 发现、依赖排序、生命周期
    mod_base.gd          mod 基类（扩展点契约）
    mod_context.gd       mod 可触碰的 API 门面
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
    player.gd            角色控制器（移动/体力/重力）
    camera_rig.gd        第三人称环绕相机
    player_scene.gd      玩家场景的代码构建
    interactable.gd      可交互物契约
    interaction_probe.gd 朝向感知的交互探测
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
mods/lighthouse/         示例 mod（用到全部扩展点）
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

示例 mod `mods/lighthouse/` 演示了全部扩展点：新地标、新散布道具、新物品、
新战斗实现、地形改造、事件监听、自身存档。

---

## 已知边界

- 战斗只有接口与参考实现，**没有**敌人 AI、伤害数字、连招或平衡。
- `M` 地图键已注册但大地图界面尚未实现；小地图（右上角俯视）可用。
- 海面是着色器平面，没有水下玩法与游泳。
- 散布的岩石/树没有 LOD；小地图尺寸下这是刻意的取舍。
- 地形使用 Terrain3D 的默认材质；未做贴图绘制管线，只做了高度分层的控制图。
